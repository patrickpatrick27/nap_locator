import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SheetService {
  // Your Google Sheet Export Link (TAB GID included)
  static const String csvUrl = 'https://docs.google.com/spreadsheets/d/1x_IsBXD0Tky4lZwg9lrIgUVR7s_rbfnC0c2L9adOwdI/export?format=csv&gid=1967251366';
  
  static const String _cacheKey = 'lcp_data_v20_master_auto_fix'; 

  Future<List<dynamic>> fetchLcpData() async {
    try {
      // Add timestamp to prevent caching from Google's side
      String uniqueUrl = '$csvUrl&v=${DateTime.now().millisecondsSinceEpoch}';
      print("Downloading Fresh Data...");

      final response = await http.get(Uri.parse(uniqueUrl)).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        String csvData = response.body;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, csvData);
        return _parseMultiColumnCsv(csvData);
      } else {
        print("Server Error ${response.statusCode}, using local cache.");
        return _loadFromCache();
      }
    } catch (e) {
      print("Network Error: $e");
      return _loadFromCache();
    }
  }

  Future<List<dynamic>> _loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedData = prefs.getString(_cacheKey);
    if (cachedData != null && cachedData.isNotEmpty) {
      return _parseMultiColumnCsv(cachedData);
    }
    return []; 
  }

  List<dynamic> _parseMultiColumnCsv(String csvString) {
    // 1. Convert CSV to Rows (Allow invalid rows to prevent total crash)
    List<List<dynamic>> rawRows = const CsvToListConverter(shouldParseNumbers: false, allowInvalid: false).convert(csvString, eol: '\n');
    
    if (rawRows.length < 3) return []; 

    Map<String, Map<String, dynamic>> lcpMap = {};
    
    // --- 2. THE HEADER HUNTER ---
    // Scan Row 2 (Index 1) for "OLT PORT" to find the start of each block.
    List<dynamic> headerRow = rawRows[1]; 
    List<int> blockStarts = [];

    print("Scanning Header Row for Anchors...");

    for (int i = 0; i < headerRow.length; i++) {
      String cell = headerRow[i].toString().toUpperCase().trim();
      if (cell == "OLT PORT") {
        blockStarts.add(i);
      }
    }

    if (blockStarts.isEmpty) {
      print("⚠️ WARNING: No 'OLT PORT' headers found. Defaulting to [0, 15, 30].");
      blockStarts = [0, 15, 30]; 
    } else {
      print("✅ Found OLT Blocks at columns: $blockStarts");
    }

    // --- 3. PROCESS ROWS WITH VIRTUAL PADDING ---
    for (var i = 2; i < rawRows.length; i++) {
      // Create a mutable copy of the row
      List<dynamic> row = List.from(rawRows[i]);
      
      // === THE CODE-SIDE BOOKEND ===
      // If row is short (e.g., 15 cols), fill it with empty text until it's 60 cols wide.
      // This ensures we can safely access Column 45+ (OLT 3) without crashing.
      while (row.length < 60) {
        row.add(""); 
      }

      // Process each OLT block found in this row
      for (int k = 0; k < blockStarts.length; k++) {
        int startIdx = blockStarts[k];
        int oltNum = k + 1; // 1, 2, 3
        
        try {
          _processBlock(row, startIdx, oltNum, lcpMap);
        } catch (e) {
          // Ignore empty blocks or bad data in just this block
        }
      }
    }

    var validLcps = lcpMap.values.where((lcp) => lcp['nps'].isNotEmpty).toList();
    validLcps.sort((a, b) => a['lcp_name'].toString().compareTo(b['lcp_name'].toString()));

    print("---------------- PARSING SUMMARY ----------------");
    print("Successfully mapped ${validLcps.length} LCPs.");
    print("-------------------------------------------------");
    
    return validLcps;
  }

  void _processBlock(List<dynamic> row, int startIdx, int oltNum, Map<String, Map<String, dynamic>> lcpMap) {
    // Relative Offsets from "OLT PORT" (StartIdx):
    // +1: LCP Name
    // +2: Site Name
    // +3..+9: Details
    // +10: NP1-2 (Coordinates)

    // Safety: Even with padding, verify we aren't looking past the absolute end
    if (row.length <= startIdx + 1) return;

    String lcpName = row[startIdx + 1].toString().trim();
    
    // SKIP INVALID ENTRIES
    if (lcpName.isEmpty || 
        lcpName.toUpperCase().contains("VACANT") || 
        lcpName.toUpperCase().contains("LCP NAME") ||
        lcpName.toUpperCase() == "0") {
      return;
    }

    if (!lcpMap.containsKey(lcpName)) {
      // Helper: Safely get string at offset
      String val(int offset) {
        int target = startIdx + offset;
        if (target < row.length) return row[target].toString().trim();
        return "";
      }

      lcpMap[lcpName] = {
        'lcp_name': lcpName,
        'site_name': val(2),
        'olt_id': oltNum,
        'details': {
          'ODF': val(3),
          'ODF Port': val(4),
          'Date': val(5),
          'Distance': val(6),
          'Rack ID': val(7),
          'New ODF': val(8),
          'New Port': val(9),
        },
        'status': 'Migrated',
        'nps': []
      };
    }

    // Extract Coordinates (Indices are relative to StartIdx)
    _addNpSafely(lcpMap[lcpName]!, "NP1-2", row, startIdx + 10);
    _addNpSafely(lcpMap[lcpName]!, "NP3-4", row, startIdx + 11);
    _addNpSafely(lcpMap[lcpName]!, "NP5-6", row, startIdx + 12);
    _addNpSafely(lcpMap[lcpName]!, "NP7-8", row, startIdx + 13);
  }

  void _addNpSafely(Map<String, dynamic> lcpObj, String npName, List<dynamic> row, int colIndex) {
    if (colIndex >= row.length) return;
    String rawValue = row[colIndex].toString();
    if (rawValue.trim().isEmpty || rawValue.toUpperCase().contains("N/A")) return;

    // SANITIZER: Allow only numbers, dots, commas, dashes
    String spacedValue = rawValue.replaceAll(RegExp(r'[^0-9.,-]'), ' ');
    List<String> chunks = spacedValue.split(RegExp(r'[ ,]+'));
    
    double? lat, lng;
    for (String chunk in chunks) {
      if (chunk.isEmpty) continue;
      double? val = double.tryParse(chunk);
      if (val != null) {
        if (lat == null) lat = val;
        else if (lng == null) { lng = val; break; }
      }
    }

    if (lat != null && lng != null) {
      // Philippines Rough Bounds: Lat 4-22, Long 116-128
      // If outside this, we reject it (likely bad data)
      if (lat > 4 && lat < 22 && lng > 116 && lng < 128) {
        lcpObj['nps'].add({'name': npName, 'lat': lat, 'lng': lng});
      }
    }
  }
}