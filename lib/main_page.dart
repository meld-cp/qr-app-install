import 'dart:async';
import 'dart:io';

import 'package:barcode_scan2/barcode_scan2.dart';
import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:install_plugin_v2/install_plugin_v2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';


class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.title});

  final String title;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  
  static const _kSimulateScanUrl = 'https://example.com/myapp.apk';

  final _requiredPermissions = [
    Permission.camera,
    Permission.requestInstallPackages
  ];
  
  final Map<Permission, PermissionStatus> _permissionStatuses = {};

  bool get _permissionsRequired =>
    ( _permissionStatuses.isEmpty && _requiredPermissions.isNotEmpty )
    || _permissionStatuses.values.any( (x) => !x.isGranted )
  ;

  String _status = "";

  String? _downloadUrl;
  double? _downloadProgress;
  CancelToken? _downloadCancelToken;

  @override
  void initState() {
    super.initState();
    unawaited( _updatePermissionStatus() );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              
              if ( _permissionsRequired )
        
                Column(
                  children: [
                    const Text( 'Some permissions are needed for this app to work', textAlign: TextAlign.center, ),
                    const SizedBox( height: 16, ),
                    ElevatedButton(
                      onPressed: _requestPermissions,
                      child: const Text( 'Request Permissions' )
                    )
                  ],
                )
              
              else if ( _downloadProgress == null )
                ElevatedButton(
                  onPressed: _scanBarcodeDownloadAndInstall,
                  child: const Text( 'Scan QR code' )
                )
              ,
        
        
              if ( _downloadProgress != null && _downloadUrl != null )
                Padding(
                  padding: const EdgeInsets.only( bottom: 32),
                  child: Column(
                    children: [
                      Text( _status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16), ),
                      const SizedBox( height: 16, ),
                      Text( '$_downloadUrl', textAlign: TextAlign.center ),
                    ],
                  ),
                )
              ,
        
              if ( _downloadProgress != null )
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 200,
                      height: 200,
                      child: CircularProgressIndicator(
                        value: _downloadProgress,
                        strokeWidth: 8,
                        strokeCap: StrokeCap.round,
                      )
                    ),
                    Column(
                      children: [
                        const SizedBox( height: 4, ),
                        Text(
                          '${(_downloadProgress! * 100.0 ).toStringAsFixed(1)}%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                        ),
                        const SizedBox( height: 8, ),
                        OutlinedButton(
                          onPressed: _cancelDownload,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          child: const Text('Cancel'),
                        )
                      ],
                    ),
                  ]
                )
              ,
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

  Future<void> _scanBarcodeDownloadAndInstall() async {

    final result = await BarcodeScanner.scan();

    debugPrint(result.type.toString()); // The result type (barcode, cancelled, failed)
    debugPrint(result.rawContent); // The barcode content
    debugPrint(result.format.toString()); // The barcode format (as enum)
    debugPrint(result.formatNote); // If a unknown format was scanned this field contains a note


    String? url;
    
    switch ( result.type ){

      case ResultType.Barcode:
        url = result.rawContent;
        break;

      case ResultType.Cancelled:
        setState(() { _status = ''; });
        break;

      case ResultType.Error:
        setState(() { _status = 'Barcode scan error'; });
        return;

    }

    if ( url == null && kDebugMode && const bool.fromEnvironment('SIMULATE_SCAN', defaultValue: false) ){
      // debug and emulator
      url = _kSimulateScanUrl;
    }

    if ( url == null ){
      return;
    }

    // download
    final Directory? downloadDir = await getDownloadsDirectory();

    if (downloadDir == null){
      setState(() {
        _status = 'Unable to get download dir';
      });
      return;
    }
    
    if ( !await downloadDir.exists() ){
      await downloadDir.create( recursive: true );
    }

    final filePath = '${downloadDir.path}/app.apk';

    final wasDownloaded = await download( url, filePath );

    setState(() {
      _downloadCancelToken = null;
      _downloadProgress = null;
    });

    if (!wasDownloaded){
      return;
    }

    setState(() {
      _status = 'Installing...';
    });

    const appId = 'nz.co.meld.qrappinstaller';
    final res = await InstallPlugin.installApk(filePath, appId );
    
    debugPrint( 'Install result: $res');

    setState(() {
      if (res == 'Success'){
        _status = '';
      }else{
        _status = 'Install failed: $res';
      }
    });

  }


  Future<bool> download( String url, String toPath ) async{

    setState(() {
      _status = 'Downloading...';
      _downloadUrl = url;
    });

    try{

      final dio = Dio()
        ..httpClientAdapter = Http2Adapter(ConnectionManager(
          idleTimeout: const Duration(seconds: 15),
          onClientCreate: (_, config) => config.onBadCertificate = (_) => true,
        ))
      ;
      
      DateTime? lastUpdate;
    
      _downloadCancelToken = CancelToken();
      
      if ( kDebugMode && url == _kSimulateScanUrl ){
        // actual url to download
        url = 'https://10.0.16.43:5999/files/app-release.apk';
      }

      await dio.download(
        url,
        toPath,
        cancelToken: _downloadCancelToken,
        onReceiveProgress: (received, total) {
          
          _downloadProgress = total > 0 ? received/total : 0;

          final now = DateTime.now();
          if ( lastUpdate == null || now.difference(lastUpdate!).inMilliseconds > 100 ){
            lastUpdate = now;
            setState(() {});
          }

        },
        
      );

      return true;


    }on DioException catch (e){
      
      if ( e.type == DioExceptionType.cancel ) {
        setState(() {
          _status = "Download cancelled";
          _downloadCancelToken = null;
          _downloadProgress = null;
          _downloadUrl = null;
        });
      }else{
        debugPrint( e.toString() );
      }

      return false;

    }
  }

  void _cancelDownload() {
    _downloadCancelToken?.cancel();
  }

}