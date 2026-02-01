defmodule SlowArena.SurrealDB do
  @moduledoc "Thin HTTP client for SurrealDB using Req."
  require Logger

  def query(sql) do
    config = Application.fetch_env!(:slow_arena, :surrealdb)

    case Req.post("#{config[:url]}/sql",
           headers: [
             {"surreal-ns", config[:namespace]},
             {"surreal-db", config[:database]},
             {"Accept", "application/json"}
           ],
           auth: {:basic, "#{config[:username]}:#{config[:password]}"},
           body: sql
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("SurrealDB query failed (#{status}): #{inspect(body)}")
        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.error("SurrealDB connection error: #{inspect(reason)}")
        {:error, {:connection, reason}}
    end
  end

  def query!(sql) do
    case query(sql) do
      {:ok, results} ->
        case Enum.find(results, &(&1["status"] == "ERR")) do
          nil -> results
          err -> raise "SurrealDB error: #{err["result"]}"
        end

      {:error, reason} ->
        raise "SurrealDB query failed: #{inspect(reason)}"
    end
  end

  def healthy? do
    case query("INFO FOR DB") do
      {:ok, [%{"status" => "OK"} | _]} -> true
      _ -> false
    end
  end
end
