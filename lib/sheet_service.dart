import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SheetService {
  static const String csvUrl = 'https://docs.google.com/spreadsheets/d/1x_IsBXD0Tky4lZwg9lrIgUVR7s_rbfnC0c2L9adOwdI/export?format=csv&gid=1967251366';
  static const String _cacheKey = 'lcp_data_v16_force_padding'; 

  Future<List<dynamic>> fetchLcpData() async {
    try {
      String uniqueUrl = '$csvUrl&v=${DateTime.now().millisecondsSinceEpoch}';
      print("Downloading Fresh Data...");

      final response = await http.get(Uri.parse(uniqueUrl)).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        String csvData = response.body;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, csvData);
        return _parseMultiColumnCsv(csvData);
      } else {
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
    List<List<dynamic>> rawRows = const CsvToListConverter(shouldParseNumbers: false, allowInvalid: false).convert(csvString, eol: '\n');
    
    if (rawRows.length < 3) return []; 

    Map<String, Map<String, dynamic>> lcpMap = {};
    
    // 1. DYNAMICALLY FIND ANCHORS
    List<dynamic> headerRow = rawRows[1]; 
    List<int> anchorColumns = [];

    // Force scan first 50 columns
    for (int c = 0; c < headerRow.length; c++) {
      String cell = headerRow[c].toString().toUpperCase().trim();
      if (cell.contains("LCP NAME")) {
        // The block starts 1 column before "LCP NAME"
        int blockStart = c - 1; 
        if (blockStart >= 0) anchorColumns.add(blockStart);
      }
    }

    if (anchorColumns.isEmpty) anchorColumns = [0, 15, 30];
    print("✅ Using Anchors: $anchorColumns");

    // 2. PROCESS ROWS WITH PADDING
    for (var i = 2; i < rawRows.length; i++) {
      // FIX: Force the row to be at least 50 columns long
      List<dynamic> row = List.from(rawRows[i]); // Make a modifiable copy
      while (row.length < 50) {
        row.add(""); // Pad with empty strings
      }
      
      for (int k = 0; k < anchorColumns.length; k++) {
        int startIdx = anchorColumns[k];
        int oltNum = k + 1;
        
        try {
          _processBlock(row, startIdx, oltNum, lcpMap);
        } catch (e) {
          // If this prints, we know exactly where it failed
          print("❌ Error Row ${i+1} Block $oltNum: $e");
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
    // Safety: Ensure we can read "LCP Name" column
    if (row.length <= startIdx + 1) return;

    String lcpName = row[startIdx + 1].toString().trim();
    
    if (lcpName.isEmpty || 
        lcpName.toUpperCase().contains("VACANT") || 
        lcpName.toUpperCase().contains("LCP NAME")) {
      return;
    }

    if (!lcpMap.containsKey(lcpName)) {
      // Helper to safely get value without crashing
      String val(int offset) {
        int target = startIdx + offset;
        if (target < row.length) {
          return row[target].toString().trim();
        }
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

    // Coordinates
    _addNpSafely(lcpMap[lcpName]!, "NP1-2", row, startIdx + 10);
    _addNpSafely(lcpMap[lcpName]!, "NP3-4", row, startIdx + 11);
    _addNpSafely(lcpMap[lcpName]!, "NP5-6", row, startIdx + 12);
    _addNpSafely(lcpMap[lcpName]!, "NP7-8", row, startIdx + 13);
  }

  void _addNpSafely(Map<String, dynamic> lcpObj, String npName, List<dynamic> row, int colIndex) {
    if (colIndex >= row.length) return;
    String rawValue = row[colIndex].toString();
    if (rawValue.trim().isEmpty || rawValue.toUpperCase().contains("N/A")) return;

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
      if (lat > 0 && lat < 90 && lng > 0 && lng < 180) {
        lcpObj['nps'].add({'name': npName, 'lat': lat, 'lng': lng});
      }
    }
  }
}