import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:serverpod_serialization/serverpod_serialization.dart';
import 'package:serverpod_shared/config.dart';
import 'package:yaml/yaml.dart';

import '../authentication/authentication_info.dart';
import '../authentication/serviceAuthentication.dart';
import '../cache/caches.dart';
import '../database/database_config.dart';
import '../database/database_connection.dart';
import '../generated/protocol.dart' as internal;
import '../generated/endpoints.dart' as internal;
import 'endpoint_dispatch.dart';
import 'future_call.dart';
import 'runmode.dart';
import 'server.dart';
import 'session.dart';
import 'method_lookup.dart';

typedef Future<List<internal.ServerHealthMetric>> HealthCheckHandler(Serverpod pod);

class Serverpod {
  late String _runMode;
  String get runMode => _runMode;

  late ServerConfig config;
  Map<String, String> _passwords = <String, String>{};

  final AuthenticationHandler? authenticationHandler;
  final HealthCheckHandler? healthCheckHandler;
  
  final SerializationManager serializationManager;
  late SerializationManager _internalSerializationManager;

  final EndpointDispatch endpoints;

  late DatabaseConfig database;
  late Caches _caches;
  Caches get caches => _caches;

  int serverId = 0;
  late Server server;
  Server? _serviceServer;
  Server get serviceServer => _serviceServer!;

  internal.RuntimeSettings? _runtimeSettings;
  internal.RuntimeSettings get runtimeSettings => _runtimeSettings!;
  set runtimeSettings(internal.RuntimeSettings settings) {
    _runtimeSettings = settings;
    _storeRuntimeSettings(settings);
  }

  Future<void> _storeRuntimeSettings(internal.RuntimeSettings settings) async {
    try {
      DatabaseConnection dbConn = DatabaseConnection(database);

      var oldRuntimeSettings = await dbConn.findSingleRow(
          internal.tRuntimeSettings) as internal.RuntimeSettings?;
      if (oldRuntimeSettings == null) {
        settings.id = null;
        await dbConn.insert(settings);
      }

      settings.id = oldRuntimeSettings!.id;
      await dbConn.update(settings);
    }
    catch(e) {}
  }

  Future<void> reloadRuntimeSettings() async {
    try {
      DatabaseConnection dbConn = DatabaseConnection(database);

      var settings = await dbConn.findSingleRow(
          internal.tRuntimeSettings) as internal.RuntimeSettings?;
      if (settings != null)
        _runtimeSettings = settings;
    }
    catch(e) {}
  }

  final MethodLookup methodLookup = MethodLookup('generated/protocol.yaml');

  List<String>? whitelistedExternalCalls;
  
  Serverpod(List<String> args, this.serializationManager, this.endpoints, {this.authenticationHandler, this.healthCheckHandler}) {
    _internalSerializationManager = internal.Protocol();
    serializationManager.merge(_internalSerializationManager);

    // Read command line arguments
    try {
      final argParser = ArgParser()
        ..addOption('mode', abbr: 'm',
            allowed: [ServerpodRunMode.development, ServerpodRunMode.production,],
            defaultsTo: ServerpodRunMode.development)
        ..addOption('server-id', abbr: 'i', defaultsTo: '0');
      ArgResults results = argParser.parse(args);
      _runMode = results['mode'];
      serverId = int.tryParse(results['server-id']) ?? 0;
    }
    catch(e) {
      print('Unknown run mode, defaulting to development');
      _runMode = ServerpodRunMode.development;
    }

    // Load config file
    print('Mode: $_runMode');

    config = ServerConfig(_runMode, serverId);
    print(config.toString());

    // Load passwords
    try {
      String passwordYaml = File('config/passwords.yaml').readAsStringSync();
      Map passwords = loadYaml(passwordYaml);
      _passwords = passwords.cast<String, String>();
    }
    catch(_) {
      _passwords = <String, String>{};
    }

    // Setup database
    database = DatabaseConfig(serializationManager, config.dbHost!, config.dbPort!, config.dbName!, config.dbUser!, config.dbPass!);

    _caches = Caches(serializationManager, config, serverId);

    server = Server(
      serverpod: this,
      serverId: serverId,
      port: config.port ?? 8080,
      serializationManager: serializationManager,
      databaseConnection: database,
      passwords: _passwords,
      runMode: _runMode,
      caches: caches,
      authenticationHandler: authenticationHandler,
      whitelistedExternalCalls: whitelistedExternalCalls,
      endpoints: endpoints,
    );
    endpoints.initializeEndpoints(server);
  }

  Future<void> start() async {
    runZonedGuarded(
      () async {
        // Runtime settings
        try {
          DatabaseConnection dbConn = DatabaseConnection(database);

          _runtimeSettings = await dbConn.findSingleRow(internal.tRuntimeSettings) as internal.RuntimeSettings?;
          if (_runtimeSettings == null) {
            // Store default settings
            _runtimeSettings = internal.RuntimeSettings(
              logAllCalls: false,
              logAllQueries: false,
              logSlowCalls: true,
              logSlowQueries: true,
              logFailedCalls: true,
              logFailedQueries: true,
              logMalformedCalls: false,
              logLevel: internal.LogLevel.warning.index,
              slowCallDuration: 1.0,
              slowQueryDuration: 1.0,
            );
            await dbConn.insert(_runtimeSettings!);
          }
        }
        catch(e, stackTrace) {
          print('${DateTime.now()} Failed to connect to database: $e');
          print('$stackTrace');
        }

        try {
          methodLookup.load(DatabaseConnection(database));
        }
        catch(e, stackTrace) {
          print('${DateTime.now()} Failed to load method lookup: $e');
          print('$stackTrace');
        }

        await _startServiceServer();

        await server.start();
      },
      (e, stackTrace) {
        // Last resort error handling
        stderr.writeln('${DateTime.now()} Serverpod zoned error: $e');
        stderr.writeln('$stackTrace');
      }
    );
  }

  Future<void> _startServiceServer() async {

    var context = SecurityContext();
    context.useCertificateChain(sslCertificatePath(_runMode, serverId));
    context.usePrivateKey(sslPrivateKeyPath(_runMode, serverId));

    var endpoints = internal.Endpoints();

    _serviceServer = Server(
      serverpod: this,
      serverId: serverId,
      port: config.servicePort ?? 8081,
      serializationManager: _internalSerializationManager,
      databaseConnection: database,
      passwords: _passwords,
      runMode: _runMode,
      name: 'Insights',
      caches: caches,
      authenticationHandler: serviceAuthenticationHandler,
      securityContext: context,
      endpoints: endpoints,
    );
    endpoints.initializeEndpoints(_serviceServer!);

    await _serviceServer!.start();
  }

  void addFutureCall(FutureCall call, String name) {
    server.addFutureCall(call, name);
  }

  String? getPassword(String key) {
    return _passwords[key];
  }

  Future<void> log(String message, {internal.LogLevel? level, dynamic? exception, StackTrace? stackTrace}) async {
    var entry = internal.LogEntry(
      serverId: server.serverId,
      logLevel: (level ?? internal.LogLevel.info).index,
      message: message,
      time: DateTime.now(),
      exception: '$exception',
      stackTrace: '$stackTrace',
    );

    await _log(entry, null);
  }

  Future<void> _log(internal.LogEntry entry, int? sessionLogId) async {
    int serverLogLevel = (_runtimeSettings?.logLevel ?? 0);

    if (entry.logLevel >= serverLogLevel) {
      entry.sessionLogId = sessionLogId;

      bool success;

      try {
        DatabaseConnection dbConn = DatabaseConnection(database);
        success = await dbConn.insert(entry);
      }
      catch(e) {
        success = false;
      }
      if (!success)
        print('${DateTime.now()} FAILED DB LOG: $entry.message');
    }

    if (_runMode == ServerpodRunMode.development) {
      print('${internal.LogLevel.values[entry.logLevel].name.toUpperCase()}: ${entry.message}');
      if (entry.exception != null)
        print(entry.exception);
      if (entry.stackTrace != null)
        print(entry.stackTrace);
    }
  }

  Future<int?> logSession(Session session, {int? authenticatedUserId, String? exception, StackTrace? stackTrace}) async {
    Duration duration = session.duration;

    if (_runMode == ServerpodRunMode.development) {
      if (session.methodCall != null)
        print('CALL: ${session.methodCall!.endpointName}.${session.methodCall!.methodName} duration: ${duration.inMilliseconds}ms numQueries: ${session.queries.length} authenticatedUser: $authenticatedUserId');
      if (exception != null) {
        print('$exception');
        print('$stackTrace');
      }
    }

    var isSlow = duration > Duration(microseconds: (runtimeSettings.slowCallDuration * 1000000.0).toInt());

    if (runtimeSettings.logAllCalls ||
        runtimeSettings.logSlowCalls && isSlow ||
        runtimeSettings.logFailedCalls && exception != null
    ) {
      var sessionLogEntry = internal.SessionLogEntry(
        serverId: serverId,
        time: DateTime.now(),
        endpoint: session.methodCall?.endpointName,
        method: session.methodCall?.methodName,
        duration: duration.inMicroseconds / 1000000.0,
        numQueries: session.queries.length,
        slow: isSlow,
        error: exception,
        stackTrace: stackTrace?.toString(),
        authenticatedUserId: authenticatedUserId,
      );

      try {
        DatabaseConnection dbConn = DatabaseConnection(database);
        await dbConn.insert(sessionLogEntry);

        int sessionLogId = sessionLogEntry.id!;

        for (var logInfo in session.logs) {
          _log(logInfo, sessionLogId);
        }

        for (var queryInfo in session.queries) {
          if (runtimeSettings.logAllQueries ||
              runtimeSettings.logSlowQueries && queryInfo.duration > runtimeSettings.slowQueryDuration ||
              runtimeSettings.logFailedQueries && queryInfo.exception != null
          ) {
            // Log query
            queryInfo.sessionLogId = sessionLogId;
            queryInfo.serverId = serverId;
            await dbConn.insert(queryInfo);
          }
        }

        return sessionLogId;
      }
      catch(e, logStackTrace) {
        print('${DateTime.now()} FAILED TO LOG SESSION');
        if (session.methodCall != null)
          print('CALL: ${session.methodCall!.endpointName}.${session.methodCall!.methodName} duration: ${duration.inMilliseconds}ms numQueries: ${session.queries.length} authenticatedUser: $authenticatedUserId');
        print('CALL error: $exception');
        print('$logStackTrace');

        print('LOG ERRORS');
        print('$e');
        print('$logStackTrace');
        print('Current stacktrace:');
        print('${StackTrace.current}');

      }
    }

    return null;
  }

  void shutdown() {
    server.shutdown();
    _serviceServer?.shutdown();
  }
}