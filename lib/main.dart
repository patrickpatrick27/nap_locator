import 'dart:async'; 
import 'dart:math' as math; 
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cache_interceptor_file_store/dio_cache_interceptor_file_store.dart';
import 'package:url_launcher/url_launcher.dart'; // <--- NEW IMPORT

// --- SHOREBIRD IMPORTS ---
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'package:restart_app/restart_app.dart'; 

import 'sheet_service.dart';
import 'update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final dir = await getApplicationDocumentsDirectory();
  final cachePath = '${dir.path}/map_tiles';
  final cacheStore = FileCacheStore(cachePath);

  runApp(MyApp(cacheStore: cacheStore));
}

class MyApp extends StatelessWidget {
  final CacheStore cacheStore;

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
      home: MainScreen(cacheStore: cacheStore),
    );
  }
}

// --- PARENT SCREEN (Holds Data & Tabs) ---
class MainScreen extends StatefulWidget {
  final CacheStore cacheStore;
  const MainScreen({super.key, required this.cacheStore});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final _updater = ShorebirdUpdater();
  
  List<dynamic> _allLcps = [];
  bool _isLoading = true;

  // Shared Location State
  LatLng? _currentLocation;
  double _currentHeading = 0.0;
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<CompassEvent>? _compassStream;

  @override
  void initState() {
    super.initState();
    _loadData();
    _startLiveLocationUpdates();
    _checkForShorebirdUpdate();
    
    // Check for native updates (APK)
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) GithubUpdateService.checkForUpdate(context);
    });
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _compassStream?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    List<dynamic> data = await SheetService().fetchLcpData();
    if (mounted) {
      setState(() {
        _allLcps = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _checkForShorebirdUpdate() async {
    try {
      final status = await _updater.checkForUpdate();
      if (status == UpdateStatus.outdated) {
        await _updater.update();
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text("Patch Ready 🚀"),
              content: const Text("Update downloaded. Restart now?"),
              actions: [
                TextButton(
                  onPressed: () => Restart.restartApp(),
                  child: const Text("Restart Now"),
                ),
              ],
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _startLiveLocationUpdates() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 3,
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position? position) {
        if (position != null && mounted) {
          setState(() {
            _currentLocation = LatLng(position.latitude, position.longitude);
          });
        }
      },
    );

    _compassStream = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null && mounted) {
        setState(() {
          _currentHeading = event.heading!;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          // TAB 1: MAP
          MapTab(
            cacheStore: widget.cacheStore,
            allLcps: _allLcps,
            isLoading: _isLoading,
            currentLocation: _currentLocation,
            currentHeading: _currentHeading,
            onRefresh: _loadData,
          ),
          // TAB 2: LIST
          ListTab(
            allLcps: _allLcps,
            isLoading: _isLoading,
            onRefresh: _loadData,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Sites List',
          ),
        ],
      ),
    );
  }
}

// --- TAB 1: THE MAP ---
class MapTab extends StatefulWidget {
  final CacheStore cacheStore;
  final List<dynamic> allLcps;
  final bool isLoading;
  final LatLng? currentLocation;
  final double currentHeading;
  final VoidCallback onRefresh;

  const MapTab({
    super.key,
    required this.cacheStore,
    required this.allLcps,
    required this.isLoading,
    required this.currentLocation,
    required this.currentHeading,
    required this.onRefresh,
  });

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  
  List<dynamic> _filteredLcps = [];
  List<Marker> _markers = [];
  bool _isSearching = false;
  bool _isFollowingUser = false;
  final LatLng _initialCenter = const LatLng(14.1153, 120.9621);

  @override
  void initState() {
    super.initState();
    if (widget.allLcps.isNotEmpty) {
      _generateOverviewMarkers(widget.allLcps);
    }
  }

  @override
  void didUpdateWidget(MapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.allLcps != oldWidget.allLcps) {
      _generateOverviewMarkers(widget.allLcps);
    }
    if (_isFollowingUser && widget.currentLocation != null) {
      _mapController.move(widget.currentLocation!, 17.0);
    }
  }

  void _recenterOnUser() {
    if (widget.currentLocation != null) {
      setState(() => _isFollowingUser = true);
      _mapController.move(widget.currentLocation!, 17.0);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Waiting for GPS signal..."), duration: Duration(seconds: 1)),
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
    _searchFocusNode.unfocus();
    setState(() {
      _isSearching = false;
      _isFollowingUser = false;
    });

    List<Marker> npMarkers = [];
    List<LatLng> points = [];
    Color oltColor = _getOltColor(lcp['olt_id']);

    for (var np in lcp['nps']) {
      LatLng pos = LatLng(np['lat'], np['lng']);
      points.add(pos);
      npMarkers.add(
        Marker(
          point: pos,
          width: 80,
          height: 60,
          child: GestureDetector(
            onTap: () => DetailedSheet.show(context, lcp),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.black26),
                  ),
                  child: Text(np['name'], style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                Icon(Icons.radio_button_checked, color: oltColor, size: 30),
              ],
            ),
          ),
        ),
      );
    }

    setState(() => _markers = npMarkers);
    
    if (points.isNotEmpty) {
       double minLat = points.first.latitude;
       double maxLat = points.first.latitude;
       double minLng = points.first.longitude;
       double maxLng = points.first.longitude;

       for (var p in points) {
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
    DetailedSheet.show(context, lcp);
  }

  void _resetMap() {
    _searchController.clear();
    _generateOverviewMarkers(widget.allLcps);
    _mapController.move(_initialCenter, 13.0);
    setState(() {
      _isSearching = false;
      _isFollowingUser = false;
    });
  }

  void _onSearchChanged(String query) {
    if (query.isEmpty) {
      _generateOverviewMarkers(widget.allLcps);
      setState(() => _isSearching = false);
      return;
    }
    setState(() => _isSearching = true);

    final filtered = widget.allLcps.where((lcp) {
      final name = lcp['lcp_name'].toString().toLowerCase();
      final site = lcp['site_name'].toString().toLowerCase();
      final olt = "olt ${lcp['olt_id']}";
      return name.contains(query.toLowerCase()) || 
             site.contains(query.toLowerCase()) || 
             olt.contains(query.toLowerCase());
    }).toList();

    setState(() => _filteredLcps = filtered);
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
              onTap: (_, __) => _searchFocusNode.unfocus(),
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture) setState(() => _isFollowingUser = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.davepatrick.napboxlocator',
                tileProvider: CachedTileProvider(
                  store: widget.cacheStore, 
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
              if (widget.currentLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: widget.currentLocation!,
                      width: 50,
                      height: 50,
                      child: Transform.rotate(
                        angle: (widget.currentHeading * (math.pi / 180)),
                        child: const Icon(Icons.navigation, color: Colors.blue, size: 40),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Search Bar
          Positioned(
            top: 50, left: 15, right: 15,
            child: Column(
              children: [
                Card(
                  elevation: 4,
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      hintText: "Search LCP, Site, or 'OLT 1'...",
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: widget.isLoading 
                        ? Transform.scale(scale: 0.5, child: const CircularProgressIndicator(strokeWidth: 3))
                        : IconButton(
                                icon: const Icon(Icons.refresh, color: Colors.blue),
                                onPressed: widget.onRefresh,
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
                if (_isSearching && _filteredLcps.isNotEmpty)
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
                      itemCount: _filteredLcps.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        var lcp = _filteredLcps[index];
                        return ListTile(
                          title: Text(lcp['lcp_name']),
                          subtitle: Text(lcp['site_name']),
                          trailing: Text("OLT ${lcp['olt_id']}"),
                          onTap: () => _focusOnLcp(lcp),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          
          Positioned(
            top: 130, right: 15,
            child: FloatingActionButton.small(
              heroTag: "gps",
              backgroundColor: _isFollowingUser ? Colors.blue : Colors.white, 
              onPressed: _recenterOnUser,
              child: Icon(Icons.my_location, color: _isFollowingUser ? Colors.white : Colors.black87),
            ),
          ),
          
          Positioned(
            bottom: 20, right: 20,
            child: FloatingActionButton.small(
              heroTag: "reset",
              onPressed: _resetMap,
              child: const Icon(Icons.map),
            ),
          ),
        ],
      ),
    );
  }
}

// --- TAB 2: THE LIST (Strictly Separated by Site -> OLT) ---
class ListTab extends StatefulWidget {
  final List<dynamic> allLcps;
  final bool isLoading;
  final VoidCallback onRefresh;

  const ListTab({
    super.key,
    required this.allLcps,
    required this.isLoading,
    required this.onRefresh,
  });

  @override
  State<ListTab> createState() => _ListTabState();
}

class _ListTabState extends State<ListTab> {
  // Logic to Group Data: Site Name (Map Key) -> OLT ID (Map Key) -> List of LCPs
  Map<String, Map<int, List<dynamic>>> _getGroupedData() {
    Map<String, Map<int, List<dynamic>>> grouped = {};

    for (var lcp in widget.allLcps) {
      String siteName = lcp['site_name'] ?? 'Unknown Site';
      int oltId = lcp['olt_id'] ?? 0;

      // 1. Create Site Folder if not exists (e.g., TGY001, IDC001)
      if (!grouped.containsKey(siteName)) {
        grouped[siteName] = {};
      }
      
      // 2. Create OLT Sub-folder if not exists (e.g., OLT 1, OLT 2)
      if (!grouped[siteName]!.containsKey(oltId)) {
        grouped[siteName]![oltId] = [];
      }

      // 3. Add the box to that folder
      grouped[siteName]![oltId]!.add(lcp);
    }
    return grouped;
  }

  Color _getOltColor(int oltId) {
    switch (oltId) {
      case 1: return Colors.blue.shade700;
      case 2: return Colors.orange.shade800;
      case 3: return Colors.purple.shade700;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.allLcps.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 50, color: Colors.grey),
            const SizedBox(height: 10),
            const Text("No data found"),
            TextButton(onPressed: widget.onRefresh, child: const Text("Retry"))
          ],
        ),
      );
    }

    final groupedData = _getGroupedData();
    // Sort Site Names alphabetically (TGY001, IDC001, etc.)
    final sortedSites = groupedData.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text("All NAP Boxes"),
        actions: [
          IconButton(onPressed: widget.onRefresh, icon: const Icon(Icons.refresh))
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80, top: 10),
        itemCount: sortedSites.length,
        itemBuilder: (context, index) {
          String siteName = sortedSites[index];
          Map<int, List<dynamic>> oltsInSite = groupedData[siteName]!;
          List<int> sortedOlts = oltsInSite.keys.toList()..sort();

          // Calculates total NAP boxes for this site (to show in the header)
          int totalBoxes = oltsInSite.values.fold(0, (sum, list) => sum + list.length);

          return Card(
            elevation: 2,
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ExpansionTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.apartment, color: Colors.blueGrey),
              ),
              title: Text(
                siteName, 
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
              ),
              subtitle: Text(
                "$totalBoxes Boxes across ${sortedOlts.length} OLTs",
                style: TextStyle(color: Colors.grey[600], fontSize: 12)
              ),
              childrenPadding: const EdgeInsets.only(left: 10, bottom: 10),
              children: sortedOlts.map((oltId) {
                Color oltColor = _getOltColor(oltId);
                List<dynamic> lcps = oltsInSite[oltId]!;
                
                // --- LEVEL 2: OLT DROPDOWN (Inside the Site) ---
                return ExpansionTile(
                  leading: Icon(Icons.router, color: oltColor),
                  title: Text(
                    "OLT $oltId", 
                    style: TextStyle(color: oltColor, fontWeight: FontWeight.bold)
                  ),
                  subtitle: Text("${lcps.length} NAPs"),
                  children: lcps.map((lcp) {
                    
                    // --- LEVEL 3: THE ACTUAL ITEMS ---
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 20, right: 20),
                      leading: const Icon(Icons.location_on, size: 18),
                      title: Text(lcp['lcp_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(lcp['details']?['Address'] ?? lcp['site_name']),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 12),
                      onTap: () {
                         DetailedSheet.show(context, lcp);
                      },
                    );
                  }).toList(),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}

// --- SHARED BOTTOM SHEET HELPER ---
class DetailedSheet {
  static void show(BuildContext context, dynamic lcp) {
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
                  
                  // --- HEADER ---
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
                        child: Text("OLT ${lcp['olt_id']}", 
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  Text(lcp['site_name'], style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                  const Divider(height: 30),

                  // --- DETAILS SECTION ---
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
                  
                  // --- COORDINATES SECTION (UPDATED WITH URL LAUNCHER) ---
                  _buildSectionTitle("Coordinates & Navigation", themeColor),
                  ...lcp['nps'].map<Widget>((np) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: themeColor.withOpacity(0.1),
                        child: Icon(Icons.location_on, color: themeColor, size: 20),
                      ),
                      title: Text(np['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("${np['lat']}, ${np['lng']}", style: const TextStyle(fontSize: 12)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 1. COPY BUTTON
                          IconButton(
                            icon: const Icon(Icons.copy, size: 20, color: Colors.grey),
                            tooltip: "Copy Coordinates",
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: "${np['lat']}, ${np['lng']}"));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Coordinates copied! 📋"), duration: Duration(seconds: 1)),
                              );
                            },
                          ),
                          // 2. GOOGLE MAPS BUTTON
                          IconButton(
                            icon: const Icon(Icons.directions, size: 24, color: Colors.blue),
                            tooltip: "Get Directions",
                            onPressed: () => _launchMaps(np['lat'], np['lng']),
                          ),
                        ],
                      ),
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

  // --- NEW: LAUNCH GOOGLE MAPS ---
  static Future<void> _launchMaps(double lat, double lng) async {
    // Standard Universal Google Maps URL for directions
    final Uri googleUrl = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    
    try {
      if (!await launchUrl(googleUrl, mode: LaunchMode.externalApplication)) {
         throw 'Could not launch Maps';
      }
    } catch (e) {
      print("Error launching map: $e");
    }
  }

  static Color _getOltColor(int? oltId) {
    switch (oltId) {
      case 1: return Colors.blue.shade700;
      case 2: return Colors.orange.shade800;
      case 3: return Colors.purple.shade700;
      default: return Colors.grey;
    }
  }

  static Widget _buildSectionTitle(String title, Color color) {
    return Row(children: [
      Icon(Icons.info, size: 16, color: color),
      const SizedBox(width: 6),
      Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
    ]);
  }

  static Widget _buildDetailCard(String label, String? value, {bool isWide = false}) {
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
}