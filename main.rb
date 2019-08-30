require 'json'
require 'mqtt'

require 'sinatra/base'
require 'prometheus/client'
require 'prometheus/client/formats/text'

class SensorRunner
  def initialize(rtl_host:,
                 mqtt_host:,
                 meter_ids: nil,
                 rtl_port: 1234,
                 sensor_time: 30,
                 meter_time: 30)
    @sensor_time = sensor_time
    @meter_time = meter_time
    @rtl_conn = "#{rtl_host}:#{rtl_port}"
    @mqtt_host = mqtt_host
    @meter_ids = meter_ids.to_s
  end

  def run
    loop do
      do_meters
      do_sensors
    end
  end

  private

  def do_meters
    meter_json = gather(meters_cmd)
    output_meters_mqtt meter_json
    output_values meter_json
  end

  def do_sensors
    `#{sensors_cmd}`
  end

  def gather(cmd)
    `#{cmd}`.lines.map do |json|
      begin
        JSON.parse(json)
      rescue JSON::ParserError
        nil
      end
    end.compact
  end

  def meters_cmd
    return @meters_cmd if @meters_cmd

    extra = "-filterid=#{@meter_ids} -single=true" unless @meter_ids.empty?

    @meters_cmd = "/root/go/bin/rtlamr \
      #{extra} \
      -server=#{@rtl_conn} \
      -msgtype=all \
      -duration=#{@meter_time}s \
      -format=json \
      -unique"
  end

  def sensors_cmd
    "rtl_433 \
      -d rtl_tcp:#{@rtl_conn} \
      -M newmodel \
      -T #{@sensor_time} \
      -F mqtt://#{@mqtt_host}"

      # -F json
  end

  def output_values(json)
    puts json
  end

  def output_meters_mqtt(json)
    MQTT::Client.connect(@mqtt_host) do |mqtt|
      json.each do |item|
        message_type = item['Type']
        message = item['Message']

        case message_type
        when 'SCM'
          publish_scm(mqtt, message)
        when 'SCM+'
          publish_scm_plus(mqtt, message)
        when 'R900'
          publish_r900(mqtt, message)
        end
      end
    end
  end

  def publish_scm(mqtt, message)
    id = message['ID']
    type = message['Type']
    consumption = message['Consumption']

    PromRegistry.meter_consumption.set(
      {
        message_type: 'scm',
        type: type,
        id: id
      },
      consumption
    )

    mqtt.publish("rtlamr/#{id}/message_type", 'scm')
    mqtt.publish("rtlamr/#{id}/type", type)
    mqtt.publish("rtlamr/#{id}/consumption", consumption)
  end

  def publish_scm_plus(mqtt, message)
    id = message['EndpointID']
    type = message['EndpointType']
    consumption = message['Consumption']

    PromRegistry.meter_consumption.set(
      {
        message_type: 'scm+',
        type: type,
        id: id
      },
      consumption
    )

    mqtt.publish("rtlamr/#{id}/message_type", 'scm+')
    mqtt.publish("rtlamr/#{id}/type", type)
    mqtt.publish("rtlamr/#{id}/consumption", consumption)
  end

  def publish_r900(mqtt, message)
    id = message['ID']
    consumption = message['Consumption']

    PromRegistry.meter_consumption.set(
      {
        message_type: 'r900',
        id: id
      },
      consumption
    )

    mqtt.publish("rtlamr/#{id}/message_type", 'r900')
    mqtt.publish("rtlamr/#{id}/consumption/", consumption)
  end
end

class App < Sinatra::Base
  configure do
    set :server, :puma
    set :bind, '0.0.0.0'
    set :port, 9100
  end

  get '/metrics' do
    Prometheus::Client::Formats::Text.marshal(PromRegistry.registry)
  end
end

class MQTTBridge
  def initialize(mqtt_host)
    @mqtt_host = mqtt_host
  end

  def run
    MQTT::Client.connect(@mqtt_host) do |mqtt|
      mqtt.get('rtl_433/+/events') do |topic, message|
        puts "CAPTURED EVENT: #{topic} : #{message}"
        parsed = JSON.parse(message)

        model = parsed['model']
        id = parsed['id']

        temperature = parsed['temperature_C']
        humidity = parsed['humidity']
        battery = parsed['battery_ok']

        PromRegistry.rtl433_temperature.set(
          {
            id: id,
            model: model
          },
          temperature
        )

        if humidity
          PromRegistry.rtl433_humidity.set(
            {
              id: id,
              model: model
            },
            humidity
          )
        end

        if battery
          PromRegistry.rtl433_battery.set(
            {
              id: id,
              model: model
            },
            battery
          )
        end
      end
    end
  end
end

class PromRegistry
  def self.registry
    @registry = Prometheus::Client.registry
  end

  def self.rtl433_temperature
    @rtl433_temperature ||= registry.gauge(:rtl433_temperature,
                                           '433 mhz device temperature')
  end

  def self.rtl433_humidity
    @rtl433_humidity ||= registry.gauge(:rtl433_humidity,
                                           '433 mhz device humidity')
  end

  def self.rtl433_battery
    @rtl433_battery ||= registry.gauge(:rtl433_battery,
                                       '433 mhz device battery status')
  end

  def self.meter_consumption
    @meter_consumption ||= registry.gauge(:meter_consumption,
                                          'Electric meter consumption')
  end
end

Thread.new do
  SensorRunner.new(rtl_host: ENV['RTL_HOST'],
                   mqtt_host: ENV['MQTT_HOST'],
                   meter_ids: ENV['METER_IDS']).run
end

Thread.new do
  MQTTBridge.new(ENV['MQTT_HOST']).run
end

App.run!
