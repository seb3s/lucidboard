defmodule LucidboardWeb.BoardLive do
  @moduledoc "The LiveView for a Lucidboard"
  use LucidboardWeb.LiveHelper
  use Phoenix.LiveView
  import LucidboardWeb.BoardLive.Helper
  alias Ecto.Changeset

  alias Lucidboard.{
    Account,
    Board,
    BoardSettings,
    Column,
    LiveBoard,
    Presence,
    TimeMachine
  }

  alias Lucidboard.Twiddler.Op
  alias LucidboardWeb.{BoardView, DashboardLive, Endpoint}
  alias LucidboardWeb.Router.Helpers, as: Routes
  alias Phoenix.LiveView.Socket
  alias Phoenix.Socket.Broadcast

  def render(assigns) do
    BoardView.render("index.html", assigns)
  end

  def mount(%{user_id: nil}, socket) do
    socket =
      socket
      |> put_flash(:error, "You must be signed in")
      |> redirect(to: Routes.user_path(Endpoint, :signin))

    {:stop, socket}
  end

  def mount(%{path_params: %{"id" => board_id}, user_id: user_id}, socket) do
    user = user_id && Account.get(user_id)

    case LiveBoard.call(String.to_integer(board_id), :state) do
      {:ok, %{board: board, events: events}} ->
        if Account.has_role?(user, board, :observer) do
          identifier = "board:#{board.id}"
          Lucidboard.subscribe(identifier)
          presence_meta = %{lv_ref: socket.id, name: user.name}
          Presence.track(self(), identifier, user.id, presence_meta)

          socket =
            assign(socket,
              board: board,
              events: events,
              user: user,
              modal_open?: false,
              tab: :board,
              column_changeset: new_column_changeset(),
              board_settings_changeset: nil,
              board_changeset: nil,
              delete_confirming_card_id: nil,
              search: nil,
              search_opened?: false,
              role_users_suggest: []
            )

          {:ok, socket}
        else
          # Throw 404 for insufficient access.
          {:stop,
           socket
           |> put_flash(:error, "Board id #{board_id} not found!")
           |> redirect(to: Routes.live_path(socket, DashboardLive))}
        end

      {:ok, {:error, :not_found}} ->
        {:stop,
         socket
         |> put_flash(:error, "Board id #{board_id} not found!")
         |> redirect(to: Routes.live_path(socket, DashboardLive))}

      {:error, error} ->
        {:stop,
         socket
         |> put_flash(:error, error)
         |> redirect(to: Routes.live_path(socket, DashboardLive))}
    end
  end

  def terminate(_reason, socket) do
    if 1 == online_count(socket) do
      LiveBoard.stop(socket.assigns.board.id)
    end
  end

  def handle_event("tab", "options", socket) do
    {:noreply,
     assign(socket,
       tab: :options,
       board_settings_changeset:
         BoardSettings.changeset(socket.assigns.board.settings)
     )}
  end

  def handle_event("tab", tab, socket) when tab in ~w(board events options) do
    {:noreply, assign(socket, :tab, String.to_atom(tab))}
  end

  def handle_event("add_card", col_id, socket) do
    {:ok, %{card: new_card}} =
      {:add_and_lock_card, col_id: col_id, user_id: user_id(socket)}
      |> live_board_action(socket)

    {:noreply, presence_lock_card(socket, new_card)}
  end

  def handle_event("inline_edit", card_id, socket) do
    {:ok, card} = Op.card_by_id(socket.assigns.board, card_id)
    {:noreply, presence_lock_card(socket, card)}
  end

  def handle_event("card_save", form_data, socket) do
    {_, socket} = save_card(socket, form_data)
    {:noreply, socket}
  end

  def handle_event("modal_card_save", form_data, socket) do
    case save_card(socket, form_data) do
      {:ok, socket} -> {:noreply, assign(socket, :modal_open?, false)}
      {:invalid, socket} -> socket
    end
  end

  def handle_event("modal_card_edit", card_id, socket) do
    {:ok, card} = Op.card_by_id(socket.assigns.board, card_id)
    socket = socket |> presence_lock_card(card) |> assign(:modal_open?, true)
    {:noreply, socket}
  end

  def handle_event("card_cancel", _, socket) do
    board = socket.assigns.board

    card_id =
      Presence.get_for_session(
        topic(socket),
        socket.assigns.user.id,
        socket.id,
        :locked_card_id
      )

    {:ok, card} = Op.card_by_id(board, card_id)
    socket = socket |> finish_card_edit() |> assign(:modal_open?, false)

    delete_card_if_empty(socket, card)

    {:noreply, socket}
  end

  def handle_event("like", card_id, socket) do
    live_board_action({:like, id: card_id, user: user(socket)}, socket)
    {:noreply, socket}
  end

  def handle_event("unlike", card_id, socket) do
    live_board_action({:unlike, id: card_id, user: user(socket)}, socket)
    {:noreply, socket}
  end

  def handle_event("card_delete", card_id, socket) do
    {:noreply, assign(socket, :delete_confirming_card_id, card_id)}
  end

  def handle_event("card_delete_confirmed", card_id, socket) do
    live_board_action({:delete_card, id: card_id}, socket)
    {:noreply, assign(socket, :delete_confirming_card_id, nil)}
  end

  def handle_event("board_name_edit_toggle", "false", socket) do
    {:noreply, assign(socket, :board_changeset, nil)}
  end

  def handle_event("board_name_edit_toggle", _value, socket) do
    board = socket.assigns.board

    {:noreply, assign(socket, :board_changeset, Board.changeset(board))}
  end

  def handle_event("board_name_save", form_data, socket) do
    action = {:update_board_from_post, form_data["board"]}

    case live_board_action(action, socket) do
      {:ok, {:error, %Changeset{} = invalid_cs}} ->
        invalid_cs = %{invalid_cs | action: :insert}
        {:noreply, assign(socket, board_changeset: invalid_cs)}

      {:ok, %{changeset: _cs}} ->
        {:noreply, assign(socket, board_changeset: nil)}
    end
  end

  def handle_event(
        "card_delete_cancelled",
        card_id,
        %{assigns: %{delete_confirming_card_id: card_id}} = socket
      ) do
    {:noreply, assign(socket, :delete_confirming_card_id, nil)}
  end

  def handle_event("column_edit", col_id, socket) do
    {:ok, column} = Op.column_by_id(socket.assigns.board, col_id)
    changeset = Column.changeset(column, %{})
    {:noreply, assign(socket, :column_changeset, changeset)}
  end

  def handle_event("column_save", form_data, socket) do
    cs = socket.assigns.column_changeset
    is_edit = Map.get(Changeset.apply_changes(cs), :id, nil)

    subject = if is_edit, do: cs, else: %Column{}

    case Column.changeset(subject, form_data["column"]) do
      %{valid?: true} = changeset ->
        column = Changeset.apply_changes(changeset)

        action =
          if column.id,
            do: {:update_column, id: column.id, title: column.title},
            else: {:add_column, title: column.title}

        live_board_action(action, socket)

        {:noreply, assign(socket, column_changeset: new_column_changeset())}

      invalid_changeset ->
        {:noreply, assign(socket, column_changeset: invalid_changeset)}
    end
  end

  def handle_event("board_settings_save", form_data, socket) do
    action =
      {:update_board_from_post, %{"settings" => form_data["board_settings"]}}

    case live_board_action(action, socket) do
      {:ok, {:error, %Changeset{} = invalid_cs}} ->
        {:noreply,
         socket
         |> put_the_flash(
           :error,
           "Invalid board settings. Please correct and try again."
         )
         |> assign(board_settings_changeset: invalid_cs.changes.settings)}

      {:ok, %{changeset: cs}} ->
        {:noreply,
         socket
         |> put_the_flash(:info, "Board settings have been saved.")
         |> assign(
           board_settings_changeset:
             cs
             |> Changeset.apply_changes()
             |> Map.get(:settings)
             |> BoardSettings.changeset(%{})
         )}
    end
  end

  def handle_event("flip_pile", pile_id, socket) do
    live_board_action({:flip_pile, id: pile_id, user: user(socket)}, socket)
    {:noreply, socket}
  end

  def handle_event("unflip_pile", pile_id, socket) do
    live_board_action({:unflip_pile, id: pile_id, user: user(socket)}, socket)
    {:noreply, socket}
  end

  def handle_event("col_up", col_id, socket) do
    live_board_action({:move_column_up, id: col_id}, socket)
    {:noreply, socket}
  end

  def handle_event("col_down", col_id, socket) do
    live_board_action({:move_column_down, id: col_id}, socket)
    {:noreply, socket}
  end

  def handle_event("search_key", %{"q" => q}, socket) do
    {:noreply,
     assign(socket, :search, get_search_assign(q, socket.assigns.board))}
  end

  def handle_event("search_open", _, socket) do
    {:noreply, assign(socket, :search_opened?, true)}
  end

  def handle_event("search_close", _, socket) do
    {:noreply, assign(socket, :search_opened?, false)}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    {:noreply, socket |> assign(:search_opened?, false) |> assign(:tab, :board)}
  end

  def handle_event("keydown", _, socket) do
    {:noreply, socket}
  end

  def handle_event("sortby_likes", col_id, socket) do
    live_board_action({:sortby_likes, id: col_id}, socket)
    {:noreply, socket}
  end

  def handle_event("role_suggest", %{"userSearch" => input}, socket) do
    suggestions = Account.suggest_users(input)
    {:noreply, assign(socket, :role_users_suggest, suggestions)}
  end

  def handle_event("grant", %{"user" => user_id} = params, socket) do
    # Role code here is for an opera bug (maybe) where the role field doesn't
    # submit. We'll just ignore the message, in this case.
    with role when not is_nil(role) <- Map.get(params, "role"),
         {int, ""} <- Integer.parse(user_id),
         user when not is_nil(user) <- Account.get(int) do
      live_board_action({:grant, id: user.id, role: role}, socket)
    end

    {:noreply, socket}
  end

  def handle_event("revoke", user_id, socket) do
    live_board_action({:revoke, id: String.to_integer(user_id)}, socket)
    {:noreply, socket}
  end

  def handle_event("sortby_votes", col_id, socket) do
    live_board_action({:sortby_votes, id: col_id}, socket)
    {:noreply, socket}
  end

  def handle_event("delete_column", col_id, socket) do
    live_board_action({:delete_column, id: col_id}, socket)
    {:noreply, socket}
  end

  def handle_info({:update, board, event}, socket) do
    if Account.has_role?(socket.assigns.user, board, :observer) do
      events =
        if event do
          Enum.slice(
            [event | socket.assigns.events],
            0,
            TimeMachine.page_size()
          )
        else
          socket.assigns.events
        end

      socket =
        assign(socket,
          board: board,
          events: events,
          search: get_search_assign(socket.assigns.search, board)
        )

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, "The board has been made private.")
       |> redirect(to: Routes.live_path(socket, DashboardLive))}
    end
  end

  def handle_info(%Broadcast{event: "presence_diff"}, socket) do
    users = online_users(socket.assigns.board.id)
    socket = assign(socket, online_users: users)

    {:noreply, socket}
  end

  def topic(%Socket{assigns: %{board: %{id: id}}}), do: "board:#{id}"
  def topic(board_id) when is_number(board_id), do: "board:#{board_id}"
  def topic(_), do: nil
end
