defmodule MetricsReporterUI.MetricsChannel do
	use Phoenix.Channel
  require Logger

  alias MonitoringHubUtils.MessageLog
  alias MonitoringHubUtils.Stores.AppConfigStore
  alias MetricsReporterUI.{AppConfigBroadcaster, ThroughputsBroadcaster, ThroughputStatsBroadcaster, LatencyStatsBroadcaster}

  def join("metrics:" <> app_name, join_message, socket) do
    %{"worker_name" => worker_name} = join_message
    _response = AppConfigBroadcaster.start_link app_name
    {:ok, _response} = AppConfigStore.add_worker_to_app_config(app_name, worker_name)
    {:ok, socket}
  end

  def handle_in("metrics", metrics_msg, socket) do
    "metrics:" <> app_name = socket.topic
    %{"category" => category, "latency_list" => latency_list,
      "timestamp" => end_timestamp, "period" => period, "name" => pipeline_key,
      "min" => min, "max" => max} = metrics_msg
    start_timestamp = end_timestamp - period
    latency_list_msg = create_latency_list_msg(pipeline_key, end_timestamp, latency_list)
    store_latency_list_msg(app_name, category, pipeline_key, latency_list_msg)
    throughput_msg = create_throughput_msg_from_latency_list(pipeline_key, end_timestamp, period, latency_list)
    store_period_throughput_msg(app_name, category, pipeline_key, throughput_msg)
    {_response, _pid} = find_or_start_latency_bins_worker(app_name, category, pipeline_key)
    {_response, _pid} = find_or_start_throughput_workers(app_name, category, pipeline_key)
    {:noreply, socket}
  end

  def handle_in("step-metrics", metrics_collection, socket) do
    "metrics:" <> app_name = socket.topic
    Enum.each(metrics_collection, fn (%{"pipeline_key" => pipeline_key,
      "t0" => _start_timestamp, "t1" => end_timestamp,
      "category" => "step" = category,
      "topics" => %{"latency_bins" => latency_bins,
      "throughput_out" => throughput_data}}) ->
      int_end_timestamp = float_timestamp_to_int(end_timestamp)
      latency_bins_msg = create_latency_bins_msg(pipeline_key, int_end_timestamp, latency_bins)
      store_latency_bins_msg(app_name, category, pipeline_key, latency_bins_msg)
      {:ok, _pid} = find_or_start_latency_bins_worker(app_name, category, pipeline_key)
      store_throughput_msgs(app_name, category, pipeline_key, throughput_data)
      {:ok, _pid} = find_or_start_throughput_workers(app_name, category, pipeline_key)
    end)
    {:reply, :ok, socket}
  end

  def handle_in("ingress-egress-metrics", metrics_collection, socket) do
    "metrics:" <> app_name = socket.topic
    Enum.each(metrics_collection, fn (%{"pipeline_key" => pipeline_key,
      "t0" => _start_timestamp, "t1" => end_timestamp,
      "category" => "ingress-egress" = category,
      "topics" => %{"latency_bins" => latency_bins,
      "throughput_out" => throughput_data}}) ->
      int_end_timestamp = float_timestamp_to_int(end_timestamp)
      latency_bins_msg = create_latency_bins_msg(pipeline_key, int_end_timestamp, latency_bins)
      store_latency_bins_msg(app_name, category, pipeline_key, latency_bins_msg)
      {:ok, _pid} = find_or_start_latency_bins_worker(app_name, category, pipeline_key)
      store_throughput_msgs(app_name, category, pipeline_key, throughput_data)
      {:ok, _pid} = find_or_start_throughput_workers(app_name, category, pipeline_key)
    end)
    {:reply, :ok, socket}
  end

  def handle_in("source-sink-metrics", metrics_collection, socket) do
    "metrics:" <> app_name = socket.topic
    Enum.each(metrics_collection, fn (%{"pipeline_key" => pipeline_key,
      "t0" => _start_timestamp, "t1" => end_timestamp,
      "category" => "source-sink" = category,
      "topics" => %{"latency_bins" => latency_bins,
      "throughput_out" => throughput_data}}) ->
      int_end_timestamp = float_timestamp_to_int(end_timestamp)
      latency_bins_msg = create_latency_bins_msg(pipeline_key, int_end_timestamp, latency_bins)
      store_latency_bins_msg(app_name, category, pipeline_key, latency_bins_msg)
      {:ok, _pid} = find_or_start_latency_bins_worker(app_name, category, pipeline_key)
      store_throughput_msgs(app_name, category, pipeline_key, throughput_data)
      {:ok, _pid} = find_or_start_throughput_workers(app_name, category, pipeline_key)
    end)
    {:reply, :ok, socket}
  end

  defp float_timestamp_to_int(timestamp) do
    round(timestamp)
  end

  defp create_latency_bins_msg(pipeline_key, timestamp, latency_bins) do
    %{"time" => timestamp, "pipeline_key" => pipeline_key, "latency_bins" => latency_bins}
  end

  defp create_latency_list_msg(pipeline_key, timestamp, latency_list) do
    %{"time" => timestamp, "pipeline_key" => pipeline_key, "latency_list" => latency_list}
  end

  defp store_latency_bins_msg(app_name, category, pipeline_key, latency_bins_msg) do
    log_name = generate_latency_bins_log_name(app_name, category, pipeline_key)
    :ok = MessageLog.Supervisor.lookup_or_create(log_name)
    MessageLog.log_message(log_name, latency_bins_msg)
  end

  defp store_latency_list_msg(app_name, category, pipeline_key, latency_list_msg) do
    log_name = generate_latency_bins_log_name(app_name, category, pipeline_key)
    :ok = MessageLog.Supervisor.lookup_or_create(log_name)
    MessageLog.log_latency_list_message(log_name, latency_list_msg)
  end

  defp store_throughput_msgs(app_name, category, pipeline_key, throughput_data) do
    timestamps = Map.keys(throughput_data)
    Enum.each(timestamps, fn timestamp ->
      int_timestamp = String.to_integer timestamp
      throughput = throughput_data[timestamp]
      throughput_msg = create_throughput_msg(int_timestamp, pipeline_key, throughput)
      store_throughput_msg(app_name, category, pipeline_key, throughput_msg)
    end)
  end

  defp create_throughput_msg(timestamp, pipeline_key, throughput) do
    %{"time" => timestamp, "pipeline_key" => pipeline_key, "total_throughput" => throughput}
  end

  defp create_throughput_msg_from_latency_list(pipeline_key, timestamp, period, latency_list) do
    total_throughput = latency_list
      |> Enum.reduce(0, fn bin_count, acc -> bin_count + acc end)
    %{"time" => timestamp, "pipeline_key" => pipeline_key,
      "period" => period, "total_throughput" => total_throughput}
  end

  defp store_throughput_msg(app_name, category, pipeline_key, throughput_msg) do
    log_name = generate_throughput_log_name(app_name, category, pipeline_key)
    :ok = MessageLog.Supervisor.lookup_or_create log_name
    MessageLog.log_throughput_message(log_name, throughput_msg)
  end

  defp store_period_throughput_msg(app_name, category, pipeline_key, period_throughput_msg) do
    log_name = generate_throughput_log_name(app_name, category, pipeline_key)
    :ok = MessageLog.Supervisor.lookup_or_create log_name
    MessageLog.log_period_throughput_message(log_name, period_throughput_msg)
  end

  defp generate_throughput_log_name(app_name, category, pipeline_key) do
    "app_name:" <> app_name <> "::category:" <> category <> "::throughput:" <> pipeline_key
  end

  defp generate_latency_bins_log_name(app_name, category, pipeline_key) do
    "app_name:" <> app_name <> "::category:" <> category <> "::latency-bins:" <> pipeline_key
  end

  defp find_or_start_throughput_workers(app_name, category, pipeline_key) do
    log_name = generate_throughput_log_name(app_name, category, pipeline_key)
    total_throughput_args = [log_name: log_name, interval_key: "last-1-sec", pipeline_key: pipeline_key, app_name: app_name, category: category]
    ThroughputsBroadcaster.Supervisor.find_or_start_worker(total_throughput_args)
    throughput_stats_args = [log_name: log_name, interval_key: "last-5-mins", pipeline_key: pipeline_key, app_name: app_name, category: category, stats_interval: 300]
    ThroughputStatsBroadcaster.Supervisor.find_or_start_worker(throughput_stats_args)
  end

  defp find_or_start_latency_bins_worker(app_name, category, pipeline_key) do
    log_name = generate_latency_bins_log_name(app_name, category, pipeline_key)
    args = [log_name: log_name, interval_key: "last-5-mins",  pipeline_key: pipeline_key,
      aggregate_interval: 300, app_name: app_name, category: category]
    LatencyStatsBroadcaster.Supervisor.find_or_start_worker(args)
  end
end
