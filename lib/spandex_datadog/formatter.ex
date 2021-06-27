defmodule SpandexDatadog.Formatter do
  @moduledoc """
  Formats Traces for sending to Datadog
  """

  alias Spandex.{Span, Trace}

  @deprecated "Please use format/3 instead"
  @spec format(Trace.t()) :: map()
  def format(%Trace{spans: spans, priority: priority, baggage: baggage}) do
    Enum.map(spans, fn span -> format(span, priority, baggage) end)
  end

  @deprecated "Please use format/3 instead"
  @spec format(Span.t()) :: map()
  def format(%Span{} = span), do: format(span, 1, [])

  @spec format(Span.t(), integer(), Keyword.t()) :: map()
  def format(%Span{} = span, priority, _baggage) do
    %{
      trace_id: span.trace_id,
      span_id: span.id,
      name: span.name,
      start: span.start,
      duration: (span.completion_time || SpandexDatadog.Adapter.now()) - span.start,
      parent_id: span.parent_id,
      error: error(span.error),
      resource: span.resource || span.name,
      service: span.service,
      type: span.type,
      meta: meta(span),
      metrics:
        metrics(span, %{
          _sampling_priority_v1: priority
        })
    }
    |> deep_remove_nils()
  end

  @spec error(nil | Keyword.t()) :: integer
  defp error(nil), do: 0

  defp error(keyword) do
    if Enum.any?(keyword, fn {_, v} -> not is_nil(v) end) do
      1
    else
      0
    end
  end

  @spec meta(Span.t()) :: map
  defp meta(span) do
    %{}
    |> add_datadog_meta(span)
    |> add_error_data(span)
    |> add_http_data(span)
    |> add_sql_data(span)
    |> add_tags(span)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  @spec add_datadog_meta(map, Span.t()) :: map
  defp add_datadog_meta(meta, %Span{env: nil}), do: meta

  defp add_datadog_meta(meta, %Span{env: env}) do
    Map.put(meta, :env, env)
  end

  @spec add_error_data(map, Span.t()) :: map
  defp add_error_data(meta, %{error: nil}), do: meta

  defp add_error_data(meta, %{error: error}) do
    meta
    |> add_error_type(error[:exception])
    |> add_error_message(error[:exception])
    |> add_error_stacktrace(error[:stacktrace])
  end

  @spec add_error_type(map, Exception.t() | nil) :: map
  defp add_error_type(meta, nil), do: meta
  defp add_error_type(meta, exception), do: Map.put(meta, "error.type", exception.__struct__)

  @spec add_error_message(map, Exception.t() | nil) :: map
  defp add_error_message(meta, nil), do: meta

  defp add_error_message(meta, exception),
    do: Map.put(meta, "error.msg", Exception.message(exception))

  @spec add_error_stacktrace(map, list | nil) :: map
  defp add_error_stacktrace(meta, nil), do: meta

  defp add_error_stacktrace(meta, stacktrace),
    do: Map.put(meta, "error.stack", Exception.format_stacktrace(stacktrace))

  @spec add_http_data(map, Span.t()) :: map
  defp add_http_data(meta, %{http: nil}), do: meta

  defp add_http_data(meta, %{http: http}) do
    status_code =
      if http[:status_code] do
        to_string(http[:status_code])
      end

    meta
    |> Map.put("http.url", http[:url])
    |> Map.put("http.status_code", status_code)
    |> Map.put("http.method", http[:method])
  end

  @spec add_sql_data(map, Span.t()) :: map
  defp add_sql_data(meta, %{sql_query: nil}), do: meta

  defp add_sql_data(meta, %{sql_query: sql}) do
    meta
    |> Map.put("sql.query", sql[:query])
    |> Map.put("sql.rows", sql[:rows])
    |> Map.put("sql.db", sql[:db])
  end

  @spec add_tags(map, Span.t()) :: map
  defp add_tags(meta, %{tags: nil}), do: meta

  defp add_tags(meta, %{tags: tags}) do
    tags = tags |> Keyword.delete(:analytics_event)

    Map.merge(
      meta,
      tags
      |> Enum.map(fn {k, v} -> {k, term_to_string(v)} end)
      |> Enum.into(%{})
    )
  end

  @spec metrics(Span.t(), map) :: map
  defp metrics(span, initial_value = %{}) do
    initial_value
    |> add_metrics(span)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  @spec add_metrics(map, Span.t()) :: map
  defp add_metrics(metrics, %{tags: nil}), do: metrics

  defp add_metrics(metrics, %{tags: tags}) do
    with analytics_event <- tags |> Keyword.get(:analytics_event),
         true <- analytics_event != nil do
      Map.merge(
        metrics,
        %{"_dd1.sr.eausr" => 1}
      )
    else
      _ ->
        metrics
    end
  end

  @spec deep_remove_nils(term) :: term
  defp deep_remove_nils(term) when is_map(term) do
    term
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    |> Enum.into(%{})
  end

  defp deep_remove_nils(term) when is_list(term) do
    if Keyword.keyword?(term) do
      term
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    else
      Enum.map(term, &deep_remove_nils/1)
    end
  end

  defp deep_remove_nils(term), do: term

  defp term_to_string(term) when is_binary(term), do: term
  defp term_to_string(term) when is_atom(term), do: term
  defp term_to_string(term), do: inspect(term)
end
