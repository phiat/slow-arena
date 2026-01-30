defmodule SlowArenaWeb.PageController do
  use SlowArenaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
