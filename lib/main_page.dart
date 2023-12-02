import 'dart:async';
import 'dart:io';

import 'package:barcode_scan2/barcode_scan2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:install_plugin_v2/install_plugin_v2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

enum _State{
  init,
  requestPermissions,
  waitForScan,
  processScan,
  downloading,
  installing
}

class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.title});

  final String title;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  
  static const appId = 'nz.co.meld.qrappinstaller';
  static const _kSimulateScanUrl = 'https://example.com/myapp.apk';

  _State _state = _State.init;

  AndroidDeviceInfo? androidInfo;

  final _requiredPermissions = [
    Permission.camera,
    Permission.requestInstallPackages
  ];
  
  final Map<Permission, PermissionStatus> _permissionStatuses = {};

  bool get _permissionsRequired =>
    ( _permissionStatuses.isEmpty && _requiredPermissions.isNotEmpty )
    || _permissionStatuses.values.any( (x) => !x.isGranted )
  ;

  String _error = '';
  String _message = '';

  bool _isBusy = false;
  double? _busyProgress;
  void Function()? _cancelBusyActionFunction;

  String? _downloadUrl;
  String? _downloadedFilePath;

  @override
  void initState() {
    super.initState();
    unawaited( _switchToState( _State.init, '' ) );
  }

  Future<void> _switchToState( _State newState, String error ) async {
    debugPrint( 'switchToState: $newState, $error');

    setState(() {
      _error = error;
    });

    _state = newState;

    switch( newState ){
      
      case _State.init:
        await _performInitState();
      break;

      case _State.requestPermissions:
      break;

      case _State.waitForScan:
        await _performWaitForScan();
      break;

      case _State.processScan:
        await _performProcessScan();
      break;

      case _State.downloading:
        await _performDownloading();
      break;

      case _State.installing:
        await _performInstalling();
      break;
    }

  }

  Future<void> _performInitState() async {
    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _message = 'Initialising...';
    });

    final deviceInfo = DeviceInfoPlugin();
    androidInfo = await deviceInfo.androidInfo;

    for (var p in _requiredPermissions) {
      _permissionStatuses[p] = await p.status;
    }

    if (_permissionsRequired){
      await _switchToState( _State.requestPermissions, '' );
    }else{
      await _switchToState( _State.waitForScan, '' );
    }

  }
  
  Future<void> _performWaitForScan() async {
    setState(() {
      _isBusy = false;
      _busyProgress = null;
      _cancelBusyActionFunction = null;
      _downloadedFilePath = null;
      _downloadUrl = null;
      _message = 'Scan a QR code to install an app.';
    });

  }

  Future<void> _performProcessScan() async {
    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _message = 'Scanning...';
    });

    final result = await BarcodeScanner.scan();

    debugPrint( 'scan result: ${result.type}, ${result.rawContent}' );

    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _message = 'Decoding QR code';
    });

    switch ( result.type ){

      case ResultType.Barcode:
        _downloadUrl = result.rawContent;
        await _switchToState( _State.downloading, '' );
        return;

      case ResultType.Cancelled:
        if ( kDebugMode && const bool.fromEnvironment('SIMULATE_SCAN', defaultValue: false) ){
          // debug and emulator
          _downloadUrl = _kSimulateScanUrl;
          await _switchToState( _State.downloading, '' );
        }else{
          await _switchToState( _State.waitForScan, '' );
        }
        return;

      case ResultType.Error:
        setState(() {
          _isBusy = false;
          _downloadUrl = null;
        });
        await _switchToState( _State.waitForScan, 'Barcode scan error' );
        return;

    }
  }

  Future<void> _performDownloading() async {
    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _cancelBusyActionFunction = null;
      _message = 'Connecting...';
    });

    if (_downloadUrl == null ){
      await _switchToState( _State.waitForScan, 'Invalid download URL' );
      return;
    }

    final url = _buildFinalDownloadUrl( _downloadUrl! );

    // download
    final Directory? downloadDir = await getDownloadsDirectory();

    if ( downloadDir == null ){
      await _switchToState( _State.waitForScan, 'Unable to get download directory' );
      return;
    }
    
    if ( !await downloadDir.exists() ){
      await downloadDir.create( recursive: true );
    }

    _downloadedFilePath = '${downloadDir.path}/app.apk';

    // download
    try{

      final dio = Dio()
        ..options.connectTimeout = const Duration(seconds: 30)
        ..options.receiveTimeout = const Duration(seconds: 30)
        ..httpClientAdapter = Http2Adapter(ConnectionManager(
          idleTimeout: const Duration(seconds: 15),
          onClientCreate: (_, config) => config.onBadCertificate = (_) => true,
        ))
      ;
      
    
      final downloadCancelToken = CancelToken();
      setState(() {
        _cancelBusyActionFunction = () => downloadCancelToken.cancel();
      });

      debugPrint( 'downloading: "$_downloadUrl" => "$url" => "$_downloadedFilePath"' );

      DateTime? lastProgressUpdate;

      await dio.download(
        url,
        _downloadedFilePath,
        cancelToken: downloadCancelToken,
        onReceiveProgress: (received, total) {
          
          _busyProgress = total > 0 ? received/total : 0;

          final now = DateTime.now();
          if ( lastProgressUpdate == null || now.difference(lastProgressUpdate!).inMilliseconds > 100 ){
            lastProgressUpdate = now;
            setState(() {
              _message = 'Downloading...';
            });
          }

        },
        
      );

      await _switchToState( _State.installing, '' );


    }on DioException catch (e){
      
      switch( e.type ){
        
        case DioExceptionType.connectionTimeout:
          await _switchToState( _State.waitForScan, 'Connection timeout' );
        return;
        
        case DioExceptionType.cancel:
          await _switchToState( _State.waitForScan, 'Download cancelled' );
        return;

        default:
          await _switchToState( _State.waitForScan, e.toString() );
        return;
      }

    }

  }
  
  Future<void> _performInstalling() async {
    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _message = 'Installing...';
    });
    
    if ( _downloadedFilePath == null || !await File(_downloadedFilePath!).exists() ){
      setState(() {
        _isBusy = false;
        _busyProgress = null;
      });
      await _switchToState( _State.waitForScan , 'Downloaded app not found' );
      return;
    } 
    
    await InstallPlugin.installApk(_downloadedFilePath!, appId );

    setState(() {
      _isBusy = false;
      _busyProgress = null;
    });

    await _switchToState( _State.waitForScan , '' );
    
    

  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text( widget.title, ),
      ),
      endDrawer: Drawer(
        surfaceTintColor: Theme.of(context).splashColor,
        child: Padding(
          padding: const EdgeInsets.only( top: 64, left: 16, right: 16, bottom: 16 ),
          child: Column(
            children: [
              Text('QR App Installer', style: Theme.of(context).textTheme.titleLarge,),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Image( width: 128, image: AssetImage('assets/icon.png') ),
              ),
              const SizedBox(height: 32,),

              Text('URL Parameters',  style: Theme.of(context).textTheme.titleSmall,),
              Text('ABI : ${androidInfo?.supportedAbis.firstOrNull}',),
            ],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_isBusy)
                      SizedBox(
                        width: 180,
                        height: 180,
                        child: CircularProgressIndicator(
                          value: _busyProgress,
                          strokeWidth: 8,
                          strokeCap: StrokeCap.round,
                        )
                      )
                    ,
                    const Icon(Icons.qr_code_2, size: 128, color: Colors.black12),
                    Column(
                      children: [
                        if ( _isBusy && _busyProgress != null )
                          Text(
                            '${(_busyProgress! * 100.0 ).toStringAsFixed(1)}%',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                          )
                        ,
                        if ( _cancelBusyActionFunction != null )
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: ElevatedButton(
                              onPressed: _cancelBusyActionFunction,
                              style: const ButtonStyle(visualDensity: VisualDensity.compact,),
                              child: const Text('Cancel'),
                            ),
                          )
                        ,
                      ],
                    ),
                  ]
                ),
              
              if ( _error.isNotEmpty )
                Padding(
                  padding: const EdgeInsets.symmetric( vertical: 16 ),
                  child: Text( _error, textAlign: TextAlign.center, style: const TextStyle( color: Colors.red), ),
                )
              ,
              if ( _message.isNotEmpty )
                Padding(
                  padding: const EdgeInsets.symmetric( vertical: 16 ),
                  child: Text( _message, textAlign: TextAlign.center, ),
                )
              ,
              const SizedBox( height: 16, ),

              if ( _state == _State.requestPermissions )
        
                Column(
                  children: [
                    ElevatedButton(
                      onPressed: _requestPermissions,
                      child: const Text( 'Request Permissions' )
                    )
                  ],
                )
              
              else if ( _state == _State.waitForScan )
                ElevatedButton(
                  onPressed: () async => await _switchToState( _State.processScan, '' ),
                  child: const Text( 'Scan QR code' )
                )
              ,

              if ( _downloadUrl != null )
                Text( '$_downloadUrl', textAlign: TextAlign.center )
              ,
             ],
          ),
        ),
      ),
    );
  }
  
  Future<void> _requestPermissions() async {

    for (var p in _requiredPermissions) {
      await p.request();
    }

    for (var p in _requiredPermissions) {
      _permissionStatuses[p] = await p.status;
    }

    setState(() { });
  }

  
  String _buildFinalDownloadUrl(String url) {
    if ( url == _kSimulateScanUrl ){
      debugPrint('simulate scan');
      url = 'https://github.com/meld-cp/qr-app-install/raw/dev/test/assets/app-{abi}-release.apk';
    }
    return url.replaceAll(
      RegExp('{abi}', caseSensitive: false),
      androidInfo?.supportedAbis.firstOrNull ?? ''
    );
  }


}