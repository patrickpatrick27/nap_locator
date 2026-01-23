import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart'; 
// --- NEW IMPORTS FOR OFFLINE STORAGE ---
import 'package:dio_cache_interceptor_file_store/dio_cache_interceptor_file_store.dart';
import 'package:path_provider/path_provider.dart';

// IMPORT YOUR SHEET SERVICE
import 'sheet_service.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Get a safe folder on the phone to store map tiles
  final dir = await getApplicationDocumentsDirectory();
  final cachePath = '${dir.path}/map_tiles';
  
  // 2. Create the File Store (Persists on Disk)
  final cacheStore = FileCacheStore(cachePath);

  // 3. Pass the store to the app
  runApp(MyApp(cacheStore: cacheStore));
}

class MyApp extends StatelessWidget {
  final CacheStore cacheStore; // Store is passed down

  const MyApp({super.key, required this.cacheStore});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NAP Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: MapScreen(cacheStore: cacheStore), // Pass it to MapScreen
    );
  }
}

class MapScreen extends StatefulWidget {
  final CacheStore cacheStore; // Receive it here
  const MapScreen({super.key, required this.cacheStore});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  
  List<dynamic> _allLcps = [];
  List<dynamic> _searchResults = []; 
  List<Marker> _markers = [];
  dynamic _selectedLcp;

  bool _isSearching = false;
  bool _isLoading = false; 

  final LatLng _initialCenter = const LatLng(14.1153, 120.9621);

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true); 

    // The SheetService handles CSV caching (offline data)
    List<dynamic> data = await SheetService().fetchLcpData();

    if (mounted) {
      setState(() {
        _allLcps = data;
        _isLoading = false; 
        _resetToOverview(); 
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(data.isEmpty 
              ? "Loaded offline data." 
              : "Map updated! Loaded ${data.length} NAP boxes."),
          backgroundColor: data.isEmpty ? Colors.orange : Colors.green[700],
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Color _getOltColor(int? oltId) {
    switch (oltId) {
      case 1: return Colors.blue.shade700;   
      case 2: return Colors.orange.shade800; 
      case 3: return Colors.purple.shade700; 
      default: return Colors.grey;
    }
  }

  String _getOltLabel(int? oltId) {
    return "OLT ${oltId ?? '?'}";
  }

  void _resetToOverview() {
    _generateOverviewMarkers(_allLcps);
    setState(() {
      _selectedLcp = null;
      _searchResults.clear();
      _isSearching = false;
    });
  }

  void _generateOverviewMarkers(List<dynamic> lcps) {
    List<Marker> markers = [];
    for (var lcp in lcps) {
      if (lcp['nps'] != null && lcp['nps'].isNotEmpty) {
        var firstNp = lcp['nps'][0];
        Color markerColor = _getOltColor(lcp['olt_id']);

        markers.add(
          Marker(
            point: LatLng(firstNp['lat'], firstNp['lng']),
            width: 45,
            height: 45,
            child: GestureDetector(
              onTap: () => _focusOnLcp(lcp), 
              child: Icon(Icons.location_on, color: markerColor, size: 45),
            ),
          ),
        );
      }
    }
    setState(() => _markers = markers);
  }

  void _focusOnLcp(dynamic lcp) {
    FocusScope.of(context).unfocus(); 
    setState(() {
      _isSearching = false;
      _selectedLcp = lcp;
    });

    List<Marker> npMarkers = [];
    List<LatLng> pointsForBounds = [];
    Color oltColor = _getOltColor(lcp['olt_id']);

    for (var np in lcp['nps']) {
      double lat = np['lat'];
      double lng = np['lng'];
      LatLng pos = LatLng(lat, lng);
      pointsForBounds.add(pos);

      npMarkers.add(
        Marker(
          point: pos,
          width: 80, 
          height: 60,
          child: GestureDetector(
            onTap: () => _showDetailedSheet(lcp), 
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.black26),
                  ),
                  child: Text(
                    np['name'],
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
                Icon(Icons.radio_button_checked, color: oltColor, size: 30),
              ],
            ),
          ),
        ),
      );
    }

    setState(() => _markers = npMarkers);

    if (pointsForBounds.isNotEmpty) {
       double minLat = pointsForBounds.first.latitude;
       double maxLat = pointsForBounds.first.latitude;
       double minLng = pointsForBounds.first.longitude;
       double maxLng = pointsForBounds.first.longitude;

       for (var p in pointsForBounds) {
         if (p.latitude < minLat) minLat = p.latitude;
         if (p.latitude > maxLat) maxLat = p.latitude;
         if (p.longitude < minLng) minLng = p.longitude;
         if (p.longitude > maxLng) maxLng = p.longitude;
       }
       
       if ((maxLat - minLat).abs() < 0.0001 && (maxLng - minLng).abs() < 0.0001) {
          _mapController.move(LatLng(minLat, minLng), 18.0);
       } else {
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng)),
              padding: const EdgeInsets.all(80), 
            ),
          );
       }
    }
    
    _showDetailedSheet(lcp);
  }

  void _showDetailedSheet(dynamic lcp) {
    Color themeColor = _getOltColor(lcp['olt_id']);
    Map<String, dynamic> details = lcp['details'] ?? {};

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
              ),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: ListView(
                controller: scrollController,
                children: [
                  Center(child: Container(width: 40, height: 4, color: Colors.grey[300])),
                  const SizedBox(height: 15),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(lcp['lcp_name'], 
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: themeColor,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(_getOltLabel(lcp['olt_id']), 
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  Text(lcp['site_name'], style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                  const Divider(height: 30),

                  _buildSectionTitle("Patching Details", themeColor),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _buildDetailCard("ODF", details['ODF']),
                      _buildDetailCard("ODF Port", details['ODF Port']),
                      _buildDetailCard("New ODF", details['New ODF']),
                      _buildDetailCard("New Port", details['New Port']),
                      _buildDetailCard("Rack ID", details['Rack ID']),
                      _buildDetailCard("Date/NMP", details['Date'], isWide: true),
                      _buildDetailCard("Distance", details['Distance']),
                    ],
                  ),

                  const SizedBox(height: 20),
                  _buildSectionTitle("Coordinates", themeColor),
                  ...lcp['nps'].map<Widget>((np) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.location_on_outlined, color: themeColor),
                    title: Text(np['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text("${np['lat']}, ${np['lng']}"),
                    dense: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: "${np['lat']}, ${np['lng']}"));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Coordinates copied!"), duration: Duration(seconds: 1)),
                        );
                      },
                    ),
                  )).toList(),
                  const SizedBox(height: 40),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSectionTitle(String title, Color color) {
    return Row(children: [
      Icon(Icons.info, size: 16, color: color),
      const SizedBox(width: 6),
      Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
    ]);
  }

  Widget _buildDetailCard(String label, String? value, {bool isWide = false}) {
    String displayValue = (value == null || value.isEmpty) ? "-" : value;
    return Container(
      width: isWide ? double.infinity : 100, 
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(displayValue, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  void _onSearchChanged(String query) {
    if (query.isEmpty) {
      _resetToOverview();
      return;
    }
    setState(() => _isSearching = true);

    final filtered = _allLcps.where((lcp) {
      final name = lcp['lcp_name'].toString().toLowerCase();
      final site = lcp['site_name'].toString().toLowerCase();
      final olt = "olt ${lcp['olt_id']}";
      return name.contains(query.toLowerCase()) || 
             site.contains(query.toLowerCase()) || 
             olt.contains(query.toLowerCase());
    }).toList();

    setState(() => _searchResults = filtered);
    _generateOverviewMarkers(filtered);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false, 
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _initialCenter,
              initialZoom: 13.0,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onTap: (_, __) {
                 if (_isSearching) setState(() => _isSearching = false);
                 FocusScope.of(context).unfocus();
              },
            ),
            children: [
              // --- OFFLINE TILE LAYER ---
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.davepatrick.napboxlocator',
                tileProvider: CachedTileProvider(
                  store: widget.cacheStore, // <--- SAVES TO DISK (Offline Mode)
                  maxStale: const Duration(days: 365), 
                ),
              ),
              MarkerClusterLayerWidget(
                options: MarkerClusterLayerOptions(
                  maxClusterRadius: 45,
                  size: const Size(40, 40),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(50),
                  maxZoom: 15, 
                  markers: _markers,
                  builder: (context, markers) {
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Colors.blueGrey, 
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(blurRadius: 5, color: Colors.black26)],
                      ),
                      child: Center(
                        child: Text(
                          markers.length.toString(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),

          Positioned(
            top: 50, left: 15, right: 15,
            child: Column(
              children: [
                Card(
                  elevation: 4,
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: "Search LCP, Site, or 'OLT 1'...",
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _isLoading 
                        ? Transform.scale(scale: 0.5, child: const CircularProgressIndicator(strokeWidth: 3))
                        : (_searchController.text.isNotEmpty 
                            ? IconButton(
                                icon: const Icon(Icons.clear), 
                                onPressed: () {
                                  _searchController.clear();
                                  _resetToOverview();
                                  _mapController.move(_initialCenter, 13.0);
                                },
                              ) 
                            : IconButton(
                                icon: const Icon(Icons.refresh, color: Colors.blue),
                                tooltip: "Refresh Data",
                                onPressed: _loadData, 
                              )
                          ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(15),
                    ),
                    onChanged: _onSearchChanged,
                    onTap: () {
                       if (_searchController.text.isNotEmpty) setState(() => _isSearching = true);
                    },
                  ),
                ),
                if (_isSearching && _searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    height: 250, 
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: const [BoxShadow(blurRadius: 5, color: Colors.black26)],
                    ),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: _searchResults.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        var lcp = _searchResults[index];
                        Color itemColor = _getOltColor(lcp['olt_id']);
                        return ListTile(
                          title: Text(lcp['lcp_name'], style: TextStyle(fontWeight: FontWeight.bold, color: itemColor)),
                          subtitle: Text(lcp['site_name'], maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: itemColor.withOpacity(0.1), 
                              borderRadius: BorderRadius.circular(4)
                            ),
                            child: Text("OLT ${lcp['olt_id']}", style: TextStyle(fontSize: 10, color: itemColor, fontWeight: FontWeight.bold)),
                          ),
                          onTap: () => _focusOnLcp(lcp),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          
          if (_selectedLcp != null && !_isSearching)
            Positioned(
              bottom: 20, right: 20,
              child: FloatingActionButton.extended(
                onPressed: () {
                   _resetToOverview();
                   _mapController.move(_initialCenter, 13.0);
                },
                label: const Text("Reset Map"),
                icon: const Icon(Icons.map),
              ),
            ),
        ],
      ),
    );
  }
}