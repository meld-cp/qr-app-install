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
    _switchToState( _State.init, '' );
    unawaited( _performInitState() );
  }

  Future<void> _switchToState( _State newState, String error ) async {

    if ( _state == newState ){
      return;
    }

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
    await _updateDeviceInfo();
    await _updatePermissionStatus();

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

    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _message = 'Decoding QR code';
    });

    switch ( result.type ){

      case ResultType.Barcode:
        _downloadUrl = result.rawContent;
        _switchToState( _State.downloading, '' );
        return;

      case ResultType.Cancelled:
        if ( kDebugMode && const bool.fromEnvironment('SIMULATE_SCAN', defaultValue: false) ){
          // debug and emulator
          _downloadUrl = _kSimulateScanUrl;
          _switchToState( _State.downloading, '' );
        }else{
          _switchToState( _State.waitForScan, '' );
        }
        return;

      case ResultType.Error:
        setState(() {
          _isBusy = false;
          _downloadUrl = null;
        });
        _switchToState( _State.waitForScan, 'Barcode scan error' );
        return;

    }
  }

  Future<void> _performDownloading() async {
    setState(() {
      _isBusy = true;
      _busyProgress = null;
      _cancelBusyActionFunction = null;
      _message = 'Downloading...';
    });
    
    if (_downloadUrl == null ){
      setState(() {
        _isBusy = false;
        _busyProgress = null;
        _cancelBusyActionFunction = null;
      });
      await _switchToState( _State.waitForScan, 'Invalid download URL' );
      return;
    }

    final url = _buildFinalDownloadUrl( _downloadUrl! );

    // download
    final Directory? downloadDir = await getDownloadsDirectory();

    if ( downloadDir == null ){
      setState(() {
        _isBusy = false;
        _busyProgress = null;
        _cancelBusyActionFunction = null;
      });
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
        _cancelBusyActionFunction = () {
          downloadCancelToken.cancel();
          setState(() {
            _cancelBusyActionFunction = null;
          });
        };
      });

      DateTime? lastProgressUpdate;

      final res = await dio.download(
        url,
        _downloadedFilePath,
        cancelToken: downloadCancelToken,
        onReceiveProgress: (received, total) {
          
          _busyProgress = total > 0 ? received/total : 0;

          final now = DateTime.now();
          if ( lastProgressUpdate == null || now.difference(lastProgressUpdate!).inMilliseconds > 100 ){
            lastProgressUpdate = now;
            setState(() {});
          }

        },
        
      );

      debugPrint(res.toString());

    }on DioException catch (e){
      
      switch( e.type ){
        
        case DioExceptionType.connectionTimeout:
          setState(() {
            _isBusy = false;
            _cancelBusyActionFunction = null;
            _busyProgress = null;
            _downloadUrl = null;
          });
          await _switchToState( _State.waitForScan, 'Connection timeout' );
        return;
        
        case DioExceptionType.cancel:
          setState(() {
            _isBusy = false;
            _cancelBusyActionFunction = null;
            _busyProgress = null;
            _downloadUrl = null;
          });
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
    
    if ( _downloadedFilePath == null || !await File(_downloadUrl!).exists() ){
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
              const Icon(Icons.qr_code_2, size: 128, color: Colors.black38),
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
                      const SizedBox(
                        width: 180,
                        height: 180,
                        child: CircularProgressIndicator(
                          value: null,
                          strokeWidth: 8,
                          strokeCap: StrokeCap.round,
                        )
                      )
                    ,
                    const Icon(Icons.qr_code_2, size: 128, color: Colors.black12),
                    Column(
                      children: [
                        if ( _busyProgress != null )
                          Text(
                            '${(_busyProgress! * 100.0 ).toStringAsFixed(1)}%',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                          )
                        ,
                        if ( _cancelBusyActionFunction != null )
                          OutlinedButton(
                            onPressed: _cancelBusyActionFunction,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            child: const Text('Cancel'),
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
                  onPressed: () => _switchToState( _State.processScan, '' ),
                  child: const Text( 'Scan QR code' )
                )
              ,

              if ( _downloadUrl != null )
                Text( '$_downloadUrl', textAlign: TextAlign.center )
              ,
        
              // if ( _busyProgress != null )
              //   Stack(
              //     alignment: Alignment.center,
              //     children: [
              //       SizedBox(
              //         width: 200,
              //         height: 200,
              //         child: CircularProgressIndicator(
              //           value: _busyProgress,
              //           strokeWidth: 8,
              //           strokeCap: StrokeCap.round,
              //         )
              //       ),
              //       Column(
              //         children: [
              //           const SizedBox( height: 4, ),
              //           Text(
              //             '${(_busyProgress! * 100.0 ).toStringAsFixed(1)}%',
              //             textAlign: TextAlign.center,
              //             style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
              //           ),
              //           const SizedBox( height: 8, ),
              //           OutlinedButton(
              //             onPressed: _cancelBusyActionFunction,
              //             style: const ButtonStyle(visualDensity: VisualDensity.compact),
              //             child: const Text('Cancel'),
              //           )
              //         ],
              //       ),
              //     ]
              //   )
              // ,
              // Text(
              //   '',
              //   style: Theme.of(context).textTheme.headlineMedium,
              // ),
            ],
          ),
        ),
      ),
      // floatingActionButton: FloatingActionButton(
      //   onPressed: _incrementCounter,
      //   tooltip: 'Increment',
      //   child: const Icon(Icons.add),
      // ),
    );
  }
  
  Future<void> _updatePermissionStatus() async {

    for (var p in _requiredPermissions) {
      _permissionStatuses[p] = await p.status;
    }

    setState(() {});

  }
  
  Future<void> _requestPermissions() async {

    for (var p in _requiredPermissions) {
      await p.request();
    }

    for (var p in _requiredPermissions) {
      _permissionStatuses[p] = await p.status;
    }

    //_permissionStatuses = await _requiredPermissions.request();
    //debugPrint( _permissionStatuses.toString() );
    setState(() { });
  }

  // Future<void> _scanBarcodeDownloadAndInstall() async {

  //   final result = await BarcodeScanner.scan();

  //   debugPrint(result.type.toString()); // The result type (barcode, cancelled, failed)
  //   debugPrint(result.rawContent); // The barcode content
  //   debugPrint(result.format.toString()); // The barcode format (as enum)
  //   debugPrint(result.formatNote); // If a unknown format was scanned this field contains a note


  //   String? url;
    
  //   switch ( result.type ){

  //     case ResultType.Barcode:
  //       url = result.rawContent;
  //       break;

  //     case ResultType.Cancelled:
  //       setState(() { _status = ''; });
  //       break;

  //     case ResultType.Error:
  //       setState(() { _status = 'Barcode scan error'; });
  //       return;

  //   }

  //   if ( url == null && kDebugMode && const bool.fromEnvironment('SIMULATE_SCAN', defaultValue: false) ){
  //     // debug and emulator
  //     url = _kSimulateScanUrl;
  //   }

  //   if ( url == null ){
  //     return;
  //   }

  //   url = _buildFinalDownloadUrl( url );

  //   // download
  //   final Directory? downloadDir = await getDownloadsDirectory();

  //   if (downloadDir == null){
  //     setState(() {
  //       _isBusy = false;
  //       _status = 'Unable to get download dir';
  //     });

  //     return;
  //   }
    
  //   if ( !await downloadDir.exists() ){
  //     await downloadDir.create( recursive: true );
  //   }

  //   final filePath = '${downloadDir.path}/app.apk';

  //   final wasDownloaded = await download( url, filePath );

  //   setState(() {
  //     _downloadCancelToken = null;
  //     _busyProgress = null;
  //   });

  //   if (!wasDownloaded){
  //     return;
  //   }

  //   setState(() {
  //     _status = 'Installing...';
  //   });

    
  //   final res = await InstallPlugin.installApk(filePath, appId );
    
  //   debugPrint( 'Install result: $res');

  //   setState(() {
  //     if (res == 'Success'){
  //       _status = '';
  //     }else{
  //       _status = 'Install failed: $res';
  //     }
  //   });

  // }


  // Future<bool> download( String url, String toPath ) async{

  //   setState(() {
  //     _status = 'Downloading...';
  //     _downloadUrl = url;
  //   });

  //   try{

  //     final dio = Dio()
  //       ..options.connectTimeout = const Duration(seconds: 30)
  //       ..options.receiveTimeout = const Duration(seconds: 30)
  //       ..httpClientAdapter = Http2Adapter(ConnectionManager(
  //         idleTimeout: const Duration(seconds: 15),
  //         onClientCreate: (_, config) => config.onBadCertificate = (_) => true,
  //       ))
  //     ;
      
  //     DateTime? lastUpdate;
    
  //     _downloadCancelToken = CancelToken();
      
  //     if ( kDebugMode && url == _kSimulateScanUrl ){
  //       // actual url to download
  //       url = 'https://10.0.16.43:5999/files/app-release.apk';
  //     }

  //     final res = await dio.download(
  //       url,
  //       toPath,
  //       cancelToken: _downloadCancelToken,
  //       onReceiveProgress: (received, total) {
          
  //         _busyProgress = total > 0 ? received/total : 0;

  //         final now = DateTime.now();
  //         if ( lastUpdate == null || now.difference(lastUpdate!).inMilliseconds > 100 ){
  //           lastUpdate = now;
  //           setState(() {});
  //         }

  //       },
        
  //     );

  //     debugPrint(res.toString());

  //     return true;


  //   }on DioException catch (e){
      
  //     switch( e.type ){
        
  //       case DioExceptionType.connectionTimeout:
  //         setState(() {
  //           _status = "Connection timeout";
  //           _downloadCancelToken = null;
  //           _busyProgress = null;
  //           _downloadUrl = null;
  //         });
  //       break;
        
  //       case DioExceptionType.cancel:
  //         setState(() {
  //           _status = "Download cancelled";
  //           _downloadCancelToken = null;
  //           _busyProgress = null;
  //           _downloadUrl = null;
  //         });
  //       break;

  //       default:
  //         debugPrint( e.toString() );
  //       break;
  //     }

  //     // if ( e.type == DioExceptionType.cancel ) {
  //     //   setState(() {
  //     //     _status = "Download cancelled";
  //     //     _downloadCancelToken = null;
  //     //     _downloadProgress = null;
  //     //     _downloadUrl = null;
  //     //   });
  //     // }else{
  //     //   debugPrint( e.toString() );
  //     // }

  //     return false;

  //   }
  // }

  // void _cancelDownload() {
  //   _downloadCancelToken?.cancel();
  // }
  
  Future<void> _updateDeviceInfo() async {

    final deviceInfo = DeviceInfoPlugin();
    androidInfo = await deviceInfo.androidInfo;
    
    setState(() {});

  }
  
  String _buildFinalDownloadUrl(String url) {
    if ( url == _kSimulateScanUrl ){
      return 'https://10.0.16.43:5999/files/app-release.apk';
    }
    return url.replaceAll(
      RegExp('{abi}', caseSensitive: false),
      androidInfo?.supportedAbis.firstOrNull ?? ''
    );
  }


}