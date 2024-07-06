import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/src/typed_buffer.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'URL Launcher',
      home: SplashScreen(), // Set the splash screen as the home route
      routes: {
        '/about_us': (context) => const AboutUsPage(),
      },
      theme: ThemeData(
        appBarTheme: const AppBarTheme(),
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: 1), // Adjust the duration as needed
    );
    _animation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(_controller);
    _controller.forward();

    // Navigate to the main screen after the animation completes
    _animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => HomePage()),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: _animation,
          child: MyCustomLogoWidget(), // Replace with your custom logo widget
        ),
      ),
    );
  }
}

class MyCustomLogoWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Image.asset(
        'image/Rabbitech logo.jpg'); // Replace 'assets/logo.png' with your logo image asset path
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    Key? key,
  }) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<TimeOfDay> _times = <TimeOfDay>[];
  TextEditingController _feedDoneController = TextEditingController();
  late FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;

  double _temperature = 0.0;
  double _foodLevel = 0.0; // New state variable for food level
  late MqttServerClient mqttClient;
  String receivedMessage1 = '';
  String receivedMessage2 = '';
  bool connectedToBroker = false;

  late Timer _reconnectTimer;
  int currentAlarmHour = 0;
  int currentAlarmMinute = 0;

  @override
  void initState() {
    super.initState();
    _loadTimes();
    _connectToMqtt();
    initializeLocalNotifications();
    _reconnectTimer = Timer.periodic(Duration(seconds: 10), (_) {
      if (!connectedToBroker) {
        _connectToMqtt();
      }
    });
    _feedDoneController.addListener(_onFeedDoneValueChanged);
  }

  void initializeLocalNotifications() async {
    var initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    var initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  Future<void> scheduleNotification(TimeOfDay feedingTime) async {
    // Convert DateTime to TZDateTime
    tz.TZDateTime scheduledNotificationDateTime = tz.TZDateTime(
      tz.local,
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
      feedingTime.hour,
      feedingTime.minute,
    ).subtract(Duration(minutes: 5));

    var androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'Feed Channel',
      'Channel for feeding time notifications',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    var platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.zonedSchedule(
      0, // Notification ID
      'Feeding Time Reminder',
      'Your feeding time is approaching',
      scheduledNotificationDateTime,
      platformChannelSpecifics,
      androidAllowWhileIdle: true,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> scheduleFoodLevelNotification() async {
    if (_foodLevel <= 2.0) {
      // Check if food level is less than 1.0
      var androidPlatformChannelSpecifics = AndroidNotificationDetails(
        'Food Level Channel',
        'Channel for food level notifications',
        importance: Importance.max,
        priority: Priority.high,
        ticker: 'ticker',
      );
      var platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
      );

      await flutterLocalNotificationsPlugin.show(
        1, // Notification ID
        'Food Level Alert',
        'The food level is low. Please refill the food.',
        platformChannelSpecifics,
        payload: 'Food Level Notification',
      );
    }
  }

  @override
  void dispose() {
    _reconnectTimer.cancel();
    _feedDoneController.dispose();
    super.dispose();
  }

  void _onFeedDoneValueChanged() {
    if (_feedDoneController.text == '1') {
      _sortTimes();
    }
  }

  Future<void> _loadTimes() async {
    try {
      final Directory directory = await getApplicationDocumentsDirectory();
      final File file = File('${directory.path}/times.json');

      if (file.existsSync()) {
        final String jsonString = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(jsonString);
        setState(() {
          _times = jsonList
              .map((timeString) =>
                  TimeOfDay.fromDateTime(DateFormat('HH:mm').parse(timeString)))
              .toList();
        });
      }
    } catch (e) {
      print('Error loading times: $e');
    }
  }

  Future<void> _saveTimes() async {
    try {
      final Directory directory = await getApplicationDocumentsDirectory();
      final File file = File('${directory.path}/times.json');
      final List<String> timeStrings = _times
          .map((time) => DateFormat('HH:mm')
              .format(DateTime(0, 0, 0, time.hour, time.minute)))
          .toList();
      await file.writeAsString(jsonEncode(timeStrings));
    } catch (e) {
      print('Error saving times: $e');
    }
  }

  void sendHotTemperatureNotification() async {
    var androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'Hot Temperature Channel',
      'Channel for hot temperature notifications',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    var platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.show(
      0, // Notification ID
      'Warning: Hot Temperature',
      'It\'s getting hot! The temperature is ${_temperature.toStringAsFixed(1)}°C',
      platformChannelSpecifics,
      payload: 'Hot Temperature Notification',
    );
  }

  void _connectToMqtt() async {
    final client =
        MqttServerClient('192.168.254.153', ''); // Replace with your IP address
    client.logging(on: false);

    final connMess = MqttConnectMessage()
        .withClientIdentifier('Mqtt_MyClientUniqueId')
        .authenticateAs('Rabbitech', 'rabbitech');

    client.connectionMessage = connMess;

    try {
      await client.connect();
      setState(() {
        connectedToBroker = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Connected to MQTT broker'),
        duration: Duration(seconds: 3),
      ));
      client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
        for (var message in messages) {
          final MqttPublishMessage recMess =
              message.payload as MqttPublishMessage;
          final String payload =
              MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
          if (message.topic == 'pub/sensors/cageTemp') {
            setState(() {
              receivedMessage1 = payload;
              _temperature = double.parse(receivedMessage1);
            });

            // Check if temperature exceeds 35°C
            if (_temperature >= 35.0) {
              // Trigger notification
              sendHotTemperatureNotification();
            }
          } else if (message.topic == 'pub/sensors/isFeedingDone') {
            setState(() {
              receivedMessage2 = payload;
              _feedDoneController.text = receivedMessage2;
            });
          } else if (message.topic == 'pub/sensors/qtFeedlevel') {
            setState(() {
              _foodLevel = double.parse(payload);
            });
            scheduleFoodLevelNotification();
          }
        }
      });

      client.onDisconnected = () {
        setState(() {
          connectedToBroker = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Disconnected from MQTT broker'),
          duration: Duration(seconds: 3),
        ));
        // Try to reconnect when disconnected
        _connectToMqtt();
      };

      final topic1 = 'pub/sensors/cageTemp';
      final topic2 = 'pub/sensors/isFeedingDone';
      final topic3 = 'pub/sensors/qtFeedlevel'; // New topic for food level
      client.subscribe(topic1, MqttQos.atMostOnce);
      client.subscribe(topic2, MqttQos.atMostOnce);
      client.subscribe(
          topic3, MqttQos.atMostOnce); // Subscribe to food level topic

      mqttClient = client;
    } catch (e) {
      print('Error connecting to MQTT: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to connect to MQTT broker. Retrying...'),
        duration: Duration(seconds: 5),
      ));
      // Retry connecting after 5 seconds
      Future.delayed(Duration(seconds: 5), () {
        _connectToMqtt();
      });
    }
  }

  void _addTime() {
    showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    ).then((selectedTime) {
      if (selectedTime != null) {
        setState(() {
          _times.add(selectedTime);
          _sortTimes();
        });
        _saveTimes();

        scheduleNotification(selectedTime);

        // Publish new alarm time to MQTT broker
        final String newAlarmMessage =
            'New alarm set for ${selectedTime.hour}:${selectedTime.minute}';
        mqttClient.publishMessage(
          'pub/sensors/alarm',
          MqttQos.atMostOnce,
          utf8.encode(newAlarmMessage) as Uint8Buffer,
        );
      }
    });
  }

  void _sortTimes() {
    if (receivedMessage2 == '1' && _times.isNotEmpty) {
      // Get the current alarm time
      final currentAlarmTime = _times.removeAt(0);

      // Add the current alarm time to the end of the list
      _times.add(currentAlarmTime);

      // Get the new alarm time from the list
      final newAlarmTime = _times.isNotEmpty ? _times[0] : TimeOfDay.now();

      // Update the alarm hour and minute variables
      currentAlarmHour = newAlarmTime.hour;
      currentAlarmMinute = newAlarmTime.minute;

      print('New alarm hour: $currentAlarmHour');
      print('New alarm minute: $currentAlarmMinute');

      // Publish new alarm hour to MQTT broker
      final String newHourMessage = '${newAlarmTime.hour}';
      final Uint8List encodedHourMessage = utf8.encode(newHourMessage);
      final Uint8Buffer hourBuffer = Uint8Buffer();
      hourBuffer.addAll(encodedHourMessage);
      mqttClient.publishMessage(
        'pub/sensors/qtAlarmHH',
        MqttQos.atMostOnce,
        hourBuffer,
      );

      // Publish new alarm minute to MQTT broker
      final String newMinuteMessage = '${newAlarmTime.minute}';
      final Uint8List encodedMinuteMessage = utf8.encode(newMinuteMessage);
      final Uint8Buffer minuteBuffer = Uint8Buffer();
      minuteBuffer.addAll(encodedMinuteMessage);
      mqttClient.publishMessage(
        'pub/sensors/qtAlarmMM',
        MqttQos.atMostOnce,
        minuteBuffer,
      );

      _feedDoneController.clear();
    } else {
      // Sort the times based on their hour and minute values
      _times.sort((a, b) => a.hour * 60 + a.minute - b.hour * 60 - b.minute);
    }

    _saveTimes();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
        onRefresh: _refreshData,
        child: Scaffold(
          appBar: PreferredSize(
            preferredSize: Size.fromHeight(50), // Set the preferred height here
            child: AppBar(
              title: const Text('RABBITECH'),
              backgroundColor: Color.fromARGB(255, 157, 181, 142),
            ),
          ),
          body: Row(
            children: [
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color.fromARGB(248, 204, 235, 138),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'FEEDING TIME',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      ElevatedButton.icon(
                        onPressed: _addTime,
                        icon: Icon(
                          Icons.access_time,
                          color: Color.fromARGB(255, 245, 243, 243),
                        ),
                        label: Text(
                          'Add Time',
                          style: TextStyle(
                            color: Color.fromARGB(255, 250, 249, 249),
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                        ),
                      ),
                      Row(
                        children: [
                          const Text('Feeding Time: '),
                          Expanded(
                            child: TextField(
                              controller: _feedDoneController,
                              keyboardType: TextInputType.number,
                              onChanged: (value) {
                                setState(() {
                                  receivedMessage2 =
                                      value; // Update receivedMessage2
                                });
                                if (value == '1') {
                                  _sortTimes();
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _times.length,
                          itemBuilder: (context, index) {
                            return Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: const Color.fromARGB(255, 0, 0, 0)),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              margin: const EdgeInsets.all(5),
                              child: ListTile(
                                leading: IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () {
                                    setState(() {
                                      _times.removeAt(index);
                                    });
                                    _saveTimes();
                                  },
                                ),
                                title: Text(_times[index].format(context)),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(
                color: Color.fromARGB(255, 197, 197, 144),
                thickness: 15,
              ),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color.fromARGB(255, 177, 201, 237),
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 250,
                        child: SfRadialGauge(
                          axes: <RadialAxis>[
                            RadialAxis(
                              minimum: 0,
                              maximum: 50,
                              ranges: <GaugeRange>[
                                GaugeRange(
                                  startValue: 0,
                                  endValue: 30,
                                  color: Colors.green,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                                GaugeRange(
                                  startValue: 30,
                                  endValue: 40,
                                  color: Colors.yellow,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                                GaugeRange(
                                  startValue: 40,
                                  endValue: 50,
                                  color: Colors.red,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                              ],
                              pointers: <GaugePointer>[
                                NeedlePointer(
                                  value: _temperature,
                                  enableAnimation: true,
                                  animationType: AnimationType.linear,
                                  animationDuration: 1000,
                                  needleLength: 0.6,
                                  needleEndWidth: 5,
                                  needleColor: Colors.black,
                                ),
                              ],
                              annotations: <GaugeAnnotation>[
                                GaugeAnnotation(
                                  widget: Text(
                                    '${_temperature.toInt()}°C',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 30,
                                      color: Colors.red,
                                    ),
                                  ),
                                  angle: 90,
                                  positionFactor: 0.75,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const SizedBox(
                            height: 20,
                            child: Icon(Icons.thermostat),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Temperature: ${_temperature.toStringAsFixed(1)}°C',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 250,
                        child: SfRadialGauge(
                          axes: <RadialAxis>[
                            RadialAxis(
                              minimum: 0,
                              maximum: 5,
                              ranges: <GaugeRange>[
                                GaugeRange(
                                  startValue: 1,
                                  endValue: 2,
                                  color: Colors.red,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                                GaugeRange(
                                  startValue: 2,
                                  endValue: 3,
                                  color: Colors.orange,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                                GaugeRange(
                                  startValue: 3,
                                  endValue: 4,
                                  color: Colors.yellow,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                                GaugeRange(
                                  startValue: 4,
                                  endValue: 5,
                                  color: Colors.green,
                                  startWidth: 10,
                                  endWidth: 10,
                                ),
                              ],
                              pointers: <GaugePointer>[
                                NeedlePointer(
                                  value: _foodLevel,
                                  enableAnimation: true,
                                  animationType: AnimationType.linear,
                                  animationDuration: 1000,
                                  needleLength: 0.6,
                                  needleEndWidth: 5,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          const SizedBox(
                            height: 20,
                            child: Icon(Icons.waves),
                          ),
                          const SizedBox(width: 5),
                          const Text(
                            'Food Level: ',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _foodLevel.toStringAsFixed(1),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          drawer: Drawer(
            child: Container(
              color: const Color.fromRGBO(171, 225, 180, 1),
              child: ListView(
                children: [
                  ListTile(
                    leading: Icon(Icons.person),
                    title: Text('PROFILE'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => ProfilePage()),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings),
                    title: const Text('SETUP'),
                    onTap: () {
                      // Navigate to setup page
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              SetupPage(mqttClient: mqttClient),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info),
                    title: const Text('ABOUT US'),
                    onTap: () {
                      // Navigate to about us page
                      Navigator.pushNamed(context, '/about_us');
                    },
                  ),
                ],
              ),
            ),
          ),
        ));
  }

  Future<void> _refreshData() async {
    // Add your refresh logic here
    await Future.delayed(Duration(seconds: 3)); // Simulating a refresh delay
    setState(() {
      // Update any state variables or data here
    });
  }
}

class TimeSyncPage extends StatefulWidget {
  @override
  _TimeSyncPageState createState() => _TimeSyncPageState();
}

class _TimeSyncPageState extends State<TimeSyncPage> {
  late DateTime _currentTime;

  @override
  void initState() {
    super.initState();
    _syncTime(); // Initialize time when the page is first loaded
    // Update time every second
    Timer.periodic(Duration(seconds: 1), (timer) {
      _syncTime();
    });
  }

  void _syncTime() {
    final formattedTime = DateFormat('HH:mm:ss').format(DateTime.now());
    print('Current Time: $formattedTime');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Time Sync App'),
      ),
      body: Center(
        child: Text(
          'Current Time: ${DateFormat('HH:mm:ss').format(_currentTime)}',
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Profile'),
      ),
      backgroundColor: Color.fromARGB(255, 247, 248, 249),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          ProfileDetailPage(name: 'Fernando Jose Magnaye')),
                );
              },
              child: ElevatedButton(
                onPressed: null, // Set to null to disable button's onPressed
                child: Text('Fernando Jose Magnaye'),
              ),
            ),
            SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          ProfileDetailPage(name: 'Mico Galindez')),
                );
              },
              child: ElevatedButton(
                onPressed: null,
                child: Text('Mico Galindez'),
              ),
            ),
            SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          ProfileDetailPage(name: 'John Vincent Bernal')),
                );
              },
              child: ElevatedButton(
                onPressed: null,
                child: Text('John Vincent Bernal'),
              ),
            ),
            SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          ProfileDetailPage(name: 'Noel Rocafort')),
                );
              },
              child: ElevatedButton(
                onPressed: null,
                child: Text('Noel Rocafort'),
              ),
            ),
            SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          ProfileDetailPage(name: 'Jeffre VIlla')),
                );
              },
              child: ElevatedButton(
                onPressed: null,
                child: Text('Jeffre VIlla'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfileDetailPage extends StatelessWidget {
  final String name;

  const ProfileDetailPage({Key? key, required this.name}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Profile Detail'),
      ),
      body: Center(
        child: Text('Profile Detail for $name'),
      ),
    );
  }
}

class SetupPage extends StatefulWidget {
  final MqttServerClient mqttClient;

  const SetupPage({Key? key, required this.mqttClient}) : super(key: key);

  @override
  _SetupPageState createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late TextEditingController _controller1;
  late TextEditingController _controller2;
  double _currentThreshold1 = 0.0;
  double _currentThreshold2 = 0.0;
  double _currentTemperature = 0.0; // Add current temperature variable
  late FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;
  late Timer _notificationTimer;

  int _hour = 0;
  int _minute = 0;
  int _second = 0;

  @override
  void initState() {
    super.initState();
    _controller1 = TextEditingController();
    _controller2 = TextEditingController();
    _loadThresholds(); // Load thresholds when the page is initialized
    initializeLocalNotifications();
    _startNotificationTimer();
    // Initialize temperature sensor and subscribe to updates
    _initializeTemperatureSensor();
  }

  @override
  void dispose() {
    _controller1.dispose();
    _controller2.dispose();
    _notificationTimer.cancel();
    super.dispose();
  }

  void initializeLocalNotifications() async {
    var initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    var initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  void _startNotificationTimer() {
    _notificationTimer = Timer.periodic(Duration(minutes: 5), (timer) {
      // Check if current temperature exceeds the threshold
      if (_currentTemperature > _currentThreshold1) {
        // Schedule a notification
        _showTemperatureExceededNotification();
      }
    });
  }

  void _showTemperatureExceededNotification() async {
    var androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'Temperature Exceeded Channel',
      'Channel for temperature exceeded notifications',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    var platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.show(
      0, // Notification ID
      'Temperature Exceeded',
      'The current temperature is higher than the threshold.',
      platformChannelSpecifics,
      payload: 'Temperature Exceeded Notification',
    );
  }

  // Method to initialize temperature sensor and subscribe to updates
  // Method to initialize temperature sensor and subscribe to updates
  void _initializeTemperatureSensor() {
    // Example: Subscribe to temperature updates from MQTT
    widget.mqttClient.subscribe('sub/sensors/temperature', MqttQos.atLeastOnce);
    widget.mqttClient.updates
        ?.listen((List<MqttReceivedMessage<MqttMessage>>? messages) {
      if (messages != null && messages.isNotEmpty) {
        final MqttPublishMessage receivedMessage =
            messages[0].payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
            receivedMessage.payload.message);
        setState(() {
          _currentTemperature = double.tryParse(payload) ?? 0.0;
        });

        // Check if current temperature exceeds the threshold
        if (_currentTemperature > _currentThreshold1) {
          // Schedule a notification
          _showTemperatureExceededNotification();
        }
      }
    });
  }

  void _updateThresholds() async {
    final String tempThreshold = _controller1.text.trim();
    final String foodThreshold = _controller2.text.trim();

    if (tempThreshold.isNotEmpty) {
      // Publish temperature threshold
      widget.mqttClient.publishMessage(
        'pub/sensors/qtTempThres',
        MqttQos.atMostOnce,
        Uint8Buffer()..addAll(utf8.encode(tempThreshold)),
      );
      // Save temperature threshold to local file
      await _saveThreshold('threshold1.txt', tempThreshold);
    }

    if (foodThreshold.isNotEmpty) {
      // Publish food threshold
      widget.mqttClient.publishMessage(
        'pub/sensors/qtFoodThres',
        MqttQos.atMostOnce,
        Uint8Buffer()..addAll(utf8.encode(foodThreshold)),
      );
      // Save food threshold to local file
      await _saveThreshold('threshold2.txt', foodThreshold);
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Thresholds updated successfully'),
      duration: Duration(seconds: 3),
    ));
  }

  Future<void> _saveThreshold(String fileName, String value) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$fileName');
    await file.writeAsString(value);
  }

  Future<void> _loadThresholds() async {
    final directory = await getApplicationDocumentsDirectory();
    final file1 = File('${directory.path}/threshold1.txt');
    if (file1.existsSync()) {
      final threshold1 = file1.readAsStringSync();
      setState(() {
        _currentThreshold1 = double.parse(threshold1);
        _controller1.text = threshold1;
      });
    }

    final file2 = File('${directory.path}/threshold2.txt');
    if (file2.existsSync()) {
      final threshold2 = file2.readAsStringSync();
      setState(() {
        _currentThreshold2 = double.parse(threshold2);
        _controller2.text = threshold2;
      });
    }
  }

  void _syncTime() {
    final now = DateTime.now();

    // Publish hour to topic pub/sensor/qtTimeUpdateHH
    widget.mqttClient.publishMessage(
      'pub/sensors/qtTimeUpdateHH',
      MqttQos.atMostOnce,
      Uint8Buffer()..addAll(utf8.encode(now.hour.toString())),
    );

    // Publish minute to topic pub/sensor/qtTimeUpdateMM
    widget.mqttClient.publishMessage(
      'pub/sensors/qtTimeUpdateMM',
      MqttQos.atMostOnce,
      Uint8Buffer()..addAll(utf8.encode(now.minute.toString())),
    );

    // Publish second to topic pub/sensor/qtTimeUpdateSS
    widget.mqttClient.publishMessage(
      'pub/sensors/qtTimeUpdateSS',
      MqttQos.atMostOnce,
      Uint8Buffer()..addAll(utf8.encode(now.second.toString())),
    );

    setState(() {
      _hour = now.hour;
      _minute = now.minute;
      _second = now.second;
    });

    print('Hour: $_hour, Minute: $_minute, Second: $_second');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Temperature Threshold:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '$_currentThreshold1 °C',
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller1,
              decoration: const InputDecoration(
                labelText: '°C',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            const Text(
              'Food Threshold:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '$_currentThreshold2 Grams',
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller2,
              decoration: const InputDecoration(
                labelText: 'Grams',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _updateThresholds,
              child: const Text('Update'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _syncTime,
              child: const Text('Sync Time'),
            ),
          ],
        ),
      ),
    );
  }
}

class AboutUsPage extends StatelessWidget {
  const AboutUsPage({super.key, Key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About Us'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          color: Color.fromRGBO(
              131, 168, 167, 1), // RGBO(Red, Green, Blue, Opacity)
        ),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: DefaultTextStyle(
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.black), // Add color property here
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Image.asset(
                        'image/g1.jpg',
                        height: 150,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                          'A group of computer engineering students studying at "TANAUAN CITY COLLEGE"'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                          'Consist of Individuals with dedication and hardwork with different skillset to build this project'),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Image.asset(
                        'image/comlab.jpg',
                        height: 200,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Image.asset(
                        'image/kasama.jpg',
                        height: 200,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                          'We hope this project can be use and upgrade by future researchers          ˶ᵔ ᵕ ᵔ˶'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
