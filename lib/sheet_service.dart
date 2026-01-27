import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

class SheetService {
  // 1. The ID of your spreadsheet
  static const String _spreadsheetId = '1x_IsBXD0Tky4lZwg9lrIgUVR7s_rbfnC0c2L9adOwdI';
  
  // New cache key to ensure we don't load old single-sheet data
  static const String _cacheKey = 'lcp_data_multi_sheet_v1'; 

  // 2. LIST OF ALL SHEETS TO FETCH
  // The app will loop through these one by one.
  static const List<String> _targetSheetNames = [
    "TGY001",
    "TGY002",
    "TGY003",
    "AFC001",
    "AMC001",
    "IDC001",
    "IDC002",
    "IDC003",
    "MGC001",
    "MRC001",
    "MRC002",
    "MZC001",
    "MZC002",
    "TMC002",
    "TNC001"
  ];

  Future<List<dynamic>> fetchLcpData() async {
    try {
      print("🔐 Loading credentials...");
      
      // 1. Load the JSON key from the secure asset file
      final jsonString = await rootBundle.loadString('assets/credentials.json');
      final credentials = ServiceAccountCredentials.fromJson(jsonString);

      // 2. Authenticate as the Service Account
      final client = await clientViaServiceAccount(credentials, [sheets.SheetsApi.spreadsheetsReadonlyScope]);
      final sheetsApi = sheets.SheetsApi(client);
      
      List<dynamic> allCombinedData = [];
      
      print("📡 Starting Batch Fetch for ${_targetSheetNames.length} sheets...");

      // 3. LOOP THROUGH EACH SHEET NAME
      for (String sheetName in _targetSheetNames) {
        try {
          // Fetch the entire sheet (Columns A to AZ)
          final String range = '$sheetName!A:AZ'; 
          print("   -> Fetching: $sheetName");
          
          final response = await sheetsApi.spreadsheets.values.get(_spreadsheetId, range);
          
          if (response.values != null && response.values!.isNotEmpty) {
            // Parse this specific sheet
            // We pass 'sheetName' so we know where this data came from (e.g. AFC001)
            List<dynamic> sheetData = _parseSheetData(response.values!, sheetName);
            
            allCombinedData.addAll(sheetData);
            print("      ✅ Found ${sheetData.length} items in $sheetName");
          } else {
            print("      ⚠️ $sheetName is empty or not found.");
          }
        } catch (e) {
          print("      ❌ Error fetching $sheetName: $e");
          // We catch the error here so one broken sheet doesn't crash the whole app
        }
      }
      
      client.close(); // Close the connection

      if (allCombinedData.isNotEmpty) {
        // Cache the combined data locally
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode(allCombinedData));
        
        print("🎉 Total Loaded Items: ${allCombinedData.length}");
        return allCombinedData;
      } else {
        print("⚠️ All sheets failed. Attempting to load cache.");
        return _loadFromCache();
      }

    } catch (e) {
      print("❌ Critical Error: $e");
      return _loadFromCache();
    }
  }

  Future<List<dynamic>> _loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedString = prefs.getString(_cacheKey);
    
    if (cachedString != null && cachedString.isNotEmpty) {
      print("📂 Loading from local cache...");
      return jsonDecode(cachedString);
    }
    return []; 
  }

  // --- PARSER LOGIC ---
  List<dynamic> _parseSheetData(List<List<dynamic>> rawRows, String sheetOrigin) {
    if (rawRows.length < 3) return []; 

    Map<String, Map<String, dynamic>> lcpMap = {};
    
    // 1. Scan Row 2 (Index 1) for "OLT PORT" to determine column structure
    List<dynamic> headerRow = rawRows[1]; 
    List<int> blockStarts = [];

    for (int i = 0; i < headerRow.length; i++) {
      String cell = headerRow[i].toString().toUpperCase().trim();
      if (cell == "OLT PORT") {
        blockStarts.add(i);
      }
    }

    if (blockStarts.isEmpty) {
      // Fallback if headers are missing
      blockStarts = [0, 15, 30]; 
    }

    // 2. Process Rows
    for (var i = 2; i < rawRows.length; i++) {
      List<dynamic> row = List.from(rawRows[i]);
      
      // Pad row to avoid range errors
      while (row.length < 60) {
        row.add(""); 
      }

      for (int k = 0; k < blockStarts.length; k++) {
        int startIdx = blockStarts[k];
        int oltNum = k + 1;
        
        try {
          _processBlock(row, startIdx, oltNum, lcpMap, sheetOrigin);
        } catch (e) {
          // Skip bad blocks
        }
      }
    }

    var validLcps = lcpMap.values.where((lcp) => lcp['nps'].isNotEmpty).toList();
    // Sort combined data by name
    validLcps.sort((a, b) => a['lcp_name'].toString().compareTo(b['lcp_name'].toString()));
    
    return validLcps;
  }

  void _processBlock(List<dynamic> row, int startIdx, int oltNum, Map<String, Map<String, dynamic>> lcpMap, String sheetOrigin) {
    // Relative Offsets:
    // +1: LCP Name, +2: Site, +3..+9: Details, +10: Coords

    if (row.length <= startIdx + 1) return;

    String lcpName = row[startIdx + 1].toString().trim();
    
    // Skip Invalid Rows
    if (lcpName.isEmpty || 
        lcpName.toUpperCase().contains("VACANT") || 
        lcpName.toUpperCase().contains("LCP NAME") ||
        lcpName.toUpperCase() == "0") {
      return;
    }

    // --- SMART SITE NAMING ---
    // If the "Site Name" column (index +2) is empty, use the Sheet Name (e.g. TGY001)
    String siteNameFromRow = row[startIdx + 2].toString().trim();
    String finalSiteName = siteNameFromRow.isNotEmpty ? siteNameFromRow : sheetOrigin;

    // Use a unique key combining name + sheet to avoid collisions if names duplicate across sheets
    String uniqueKey = "$lcpName-$sheetOrigin";

    if (!lcpMap.containsKey(uniqueKey)) {
      String val(int offset) {
        int target = startIdx + offset;
        if (target < row.length) return row[target].toString().trim();
        return "";
      }

      lcpMap[uniqueKey] = {
        'lcp_name': lcpName,
        'site_name': finalSiteName, 
        'olt_id': oltNum,
        'source_sheet': sheetOrigin, // Useful for debugging
        'details': {
          'ODF': val(3),
          'ODF Port': val(4),
          'Date': val(5),
          'Distance': val(6),
          'Rack ID': val(7),
          'New ODF': val(8),
          'New Port': val(9),
        },
        'nps': []
      };
    }

    // Extract Coords
    _addNpSafely(lcpMap[uniqueKey]!, "NP1-2", row, startIdx + 10);
    _addNpSafely(lcpMap[uniqueKey]!, "NP3-4", row, startIdx + 11);
    _addNpSafely(lcpMap[uniqueKey]!, "NP5-6", row, startIdx + 12);
    _addNpSafely(lcpMap[uniqueKey]!, "NP7-8", row, startIdx + 13);
  }

  void _addNpSafely(Map<String, dynamic> lcpObj, String npName, List<dynamic> row, int colIndex) {
    if (colIndex >= row.length) return;
    String rawValue = row[colIndex].toString();
    if (rawValue.trim().isEmpty || rawValue.toUpperCase().contains("N/A")) return;

    // Cleaning: Replace non-numeric chars (except . and -) with space
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
      // Basic Bounds Check (Philippines)
      if (lat > 4 && lat < 22 && lng > 116 && lng < 128) {
        lcpObj['nps'].add({'name': npName, 'lat': lat, 'lng': lng});
      }
    }
  }
}