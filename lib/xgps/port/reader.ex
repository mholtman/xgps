defmodule XGPS.Port.Reader do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def get_gps_data(pid) do
    GenServer.call(pid, :get_gps_data)
  end

  def get_port_name(pid) do
    GenServer.call(pid, :get_port_name)
  end

  defmodule State do
    defstruct [
      gps_data: nil,
      pid: nil,
      port_name: nil,
      data_buffer: nil
    ]
  end

  def init({port_name, :init_adafruit_gps}) do
    {:ok, uart_pid} = Nerves.UART.start_link
    :ok = Nerves.UART.open(uart_pid, port_name, speed: 9600, active: true)
    gps_data = %XGPS.GpsData{has_fix: false}
    state = %State{gps_data: gps_data, pid: uart_pid, port_name: port_name, data_buffer: ""}
    init_adafruit_gps(uart_pid)
    {:ok, state}
  end

  def init({:simulate}) do
    gps_data = %XGPS.GpsData{has_fix: false}
    state = %State{gps_data: gps_data, pid: :simulate, port_name: :simulate, data_buffer: ""}
    {:ok, state}
  end

  def init({port_name}) do
    {:ok, uart_pid} = Nerves.UART.start_link
    :ok = Nerves.UART.open(uart_pid, port_name, speed: 9600, active: true)
    gps_data = %XGPS.GpsData{has_fix: false}
    state = %State{gps_data: gps_data, pid: uart_pid, port_name: port_name, data_buffer: ""}
    {:ok, state}
  end

  defp init_adafruit_gps(uart_pid) do
    cmd1 = "$PMTK313,1*2E\r\n" # enable SBAS
    cmd2 = "$PMTK319,1*24\r\n" # Set SBAS to not test mode
    cmd3 = "$PMTK301,2*2E\r\n" # Enable SBAS to be used for DGPS
    cmd4 = "$PMTK286,1*23\r\n" # Enable AIC (anti-inteference)
    cmd5 = "$PMTK314,0,1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0*28\r\n" # Output only RMC & GGA
    cmd6 = "$PMTK397,0*23\r\n" # Disable nav-speed threshold
    Nerves.UART.write(uart_pid, cmd1)
    Nerves.UART.write(uart_pid, cmd2)
    Nerves.UART.write(uart_pid, cmd3)
    Nerves.UART.write(uart_pid, cmd4)
    Nerves.UART.write(uart_pid, cmd5)
    Nerves.UART.write(uart_pid, cmd6)
  end

  def handle_info({:nerves_uart, port_name, "\n"}, %State{port_name: port_name, data_buffer: ""} = state) do
    {:noreply, state}
  end

  def handle_info({:nerves_uart, port_name, "\n"}, %State{port_name: port_name} = state) do
    sentence = state.data_buffer <> "\n"
    Logger.debug(fn -> "Received: " <> sentence end)
    parsed_data = XGPS.Parser.parse_sentence(sentence)
    {updated, new_gps_data} = update_gps_data(parsed_data, state.gps_data)
    send_update_event({updated, new_gps_data})
    {:noreply, %{state | data_buffer: "", gps_data: new_gps_data}}
  end

  def handle_info({:nerves_uart, port_name, data}, %State{port_name: port_name} = state) do
    data_buffer = state.data_buffer <> data
    {:noreply, %{state | data_buffer: data_buffer}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, state}
  end

  def handle_call(:get_gps_data, _from, state) do
    {:reply, state.gps_data, state}
  end

  def handle_call(:get_port_name, _from, state) do
    {:reply, state.port_name, state}
  end

  def handle_cast({:command, command}, state) do
    Nerves.UART.write(state.pid, (command <> "\r\n"))
    {:noreply, state}
  end

  def terminate(_reason, state) do
    Nerves.UART.close(state.pid)
    Nerves.UART.stop(state.pid)
  end

  defp update_gps_data(%XGPS.Messages.RMC{} = rmc, gps_data) do
    speed = knots_to_kmh(rmc.speed_over_groud)
    new_gps_data = %{gps_data | time: rmc.time,
                                date: rmc.date,
                                latitude: rmc.latitude,
                                longitude: rmc.longitude,
                                angle: rmc.track_angle,
                                magvariation: rmc.magnetic_variation,
                                speed: speed}
    {:updated, new_gps_data}
  end

  defp update_gps_data(%XGPS.Messages.GGA{fix_quality: 0}, gps_data) do
    new_gps_data = %{gps_data | has_fix: false}
    {:updated, new_gps_data}
  end

  defp update_gps_data(%XGPS.Messages.GGA{} = gga, gps_data) do
    new_gps_data = %{gps_data | has_fix: true,
                                fix_quality: gga.fix_quality,
                                satelites: gga.number_of_satelites_tracked,
                                hdop: gga.horizontal_dilution,
                                altitude: gga.altitude,
                                geoidheight: gga.height_over_goeid,
                                latitude: gga.latitude,
                                longitude: gga.longitude}
    {:updated, new_gps_data}
  end

  # Any other message types
  defp update_gps_data(_message, gps_data), do: {:not_updated, gps_data}

  defp knots_to_kmh(speed_in_knots) when is_float(speed_in_knots) do
    speed_in_knots * 1.852
  end
  defp knots_to_kmh(_speed_in_knots), do: 0

  defp send_update_event({:not_updated, _gps_data}), do: :ok
  defp send_update_event({:updated, gps_data}) do
    Logger.debug(fn -> "New gps_data: : " <> inspect(gps_data) end)
    XGPS.Broadcaster.async_notify(gps_data)
    :ok
  end
end
