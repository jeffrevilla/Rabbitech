import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttBackgroundService {
  static late MqttServerClient client;
  static bool isConnected = false;

  // Stream controller and stream for connection state changes
  static final _connectionStateController = StreamController<bool>.broadcast();
  static Stream<bool> get onConnectionStateChanged =>
      _connectionStateController.stream;

  static Future<void> connectToBroker(
      String username, String password, String ipAddress) async {
    client = MqttServerClient(ipAddress, '');
    client.logging(on: true);
    client.setProtocolV311(); // Set MQTT protocol version for Mosquitto
    client.keepAlivePeriod = 20;

    try {
      await client.connect(
        username,
        password,
      ); // Connect with username and password
      if (client.connectionState == MqttConnectionState.connected) {
        print('Successfully connected to the MQTT broker');
        isConnected = true;
        _connectionStateController
            .add(true); // Notify listeners about connection state change
        client.onDisconnected = () {
          print('Client disconnected');
          isConnected = false;
          _connectionStateController
              .add(false); // Notify listeners about connection state change
        };
        client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
          final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
          final String message =
              MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
          print('Received message: $message');
        });
      } else {
        print('Failed to connect to the MQTT broker');
        isConnected = false;
        _connectionStateController
            .add(false); // Notify listeners about connection state change
      }
    } on Exception catch (e) {
      print('Client exception - $e');
      isConnected = false;
      _connectionStateController
          .add(false); // Notify listeners about connection state change
    }
  }

  static void disconnectFromBroker() {
    client.disconnect();
  }
}
