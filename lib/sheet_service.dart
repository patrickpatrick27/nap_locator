import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

class SheetService {
  // 1. The ID of your spreadsheet
  static const String _spreadsheetId = '1x_IsBXD0Tky4lZwg9lrIgUVR7s_rbfnC0c2L9adOwdI';
  
  static const String _cacheKey = 'lcp_data_secure_v3_dynamic'; 

  Future<List<dynamic>> fetchLcpData() async {
    try {
      print("🔐 Loading credentials...");
      
      // 1. Load the JSON key from the secure asset file
      final jsonString = await rootBundle.loadString('assets/credentials.json');
      final credentials = ServiceAccountCredentials.fromJson(jsonString);

      // 2. Authenticate as the Service Account
      final client = await clientViaServiceAccount(credentials, [sheets.SheetsApi.spreadsheetsReadonlyScope]);
      final sheetsApi = sheets.SheetsApi(client);
      
      // --- STEP 1: FIND THE NAME OF THE 3RD TAB ---
      print("🔎 Finding the 3rd Sheet...");
      
      // Fetch spreadsheet metadata (contains tab names)
      final metadata = await sheetsApi.spreadsheets.get(_spreadsheetId);
      
      String targetSheetName;
      
      // Check if we have at least 3 sheets (Index 0, 1, 2)
      if (metadata.sheets != null && metadata.sheets!.length >= 3) {
        // Get the title of the 3rd sheet (Index 2)
        targetSheetName = metadata.sheets![2].properties!.title!;
        print("✅ Found Target Sheet: '$targetSheetName'");
      } else {
        print("⚠️ Less than 3 sheets found. Defaulting to 'Sheet1'.");
        targetSheetName = 'Sheet1';
      }

      // --- STEP 2: FETCH DATA FROM THAT SPECIFIC TAB ---
      final String dynamicRange = '$targetSheetName!A:AZ';
      
      print("📡 Fetching Data from: $dynamicRange");
      final response = await sheetsApi.spreadsheets.values.get(_spreadsheetId, dynamicRange);
      
      client.close(); // Close the connection

      if (response.values != null && response.values!.isNotEmpty) {
        // Cache the raw data as a JSON string
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode(response.values));

        return _parseSheetData(response.values!);
      } else {
        print("⚠️ Sheet is empty or permission denied.");
        return _loadFromCache();
      }

    } catch (e) {
      print("❌ Error fetching data: $e");
      print("👉 Make sure 'nap-finder-bot' has 'Viewer' access to the Sheet.");
      return _loadFromCache();
    }
  }

  Future<List<dynamic>> _loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedString = prefs.getString(_cacheKey);
    
    if (cachedString != null && cachedString.isNotEmpty) {
      print("📂 Loading from local cache...");
      // Decode JSON string back to List<List<dynamic>>
      List<dynamic> decoded = jsonDecode(cachedString);
      // Ensure strict typing for the parser
      List<List<dynamic>> rows = decoded.map((row) => (row as List).cast<dynamic>()).toList();
      return _parseSheetData(rows);
    }
    return []; 
  }

  // --- PARSER LOGIC ---
  List<dynamic> _parseSheetData(List<List<dynamic>> rawRows) {
    if (rawRows.length < 3) return []; 

    Map<String, Map<String, dynamic>> lcpMap = {};
    
    // 1. Scan Row 2 (Index 1) for "OLT PORT"
    List<dynamic> headerRow = rawRows[1]; 
    List<int> blockStarts = [];

    for (int i = 0; i < headerRow.length; i++) {
      String cell = headerRow[i].toString().toUpperCase().trim();
      if (cell == "OLT PORT") {
        blockStarts.add(i);
      }
    }

    if (blockStarts.isEmpty) {
      print("⚠️ No 'OLT PORT' headers found. Using defaults.");
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
          _processBlock(row, startIdx, oltNum, lcpMap);
        } catch (e) {
          // Skip bad blocks
        }
      }
    }

    var validLcps = lcpMap.values.where((lcp) => lcp['nps'].isNotEmpty).toList();
    validLcps.sort((a, b) => a['lcp_name'].toString().compareTo(b['lcp_name'].toString()));
    
    print("✅ Parsed ${validLcps.length} LCPs.");
    return validLcps;
  }

  void _processBlock(List<dynamic> row, int startIdx, int oltNum, Map<String, Map<String, dynamic>> lcpMap) {
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

    if (!lcpMap.containsKey(lcpName)) {
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
        'nps': []
      };
    }

    // Extract Coords
    _addNpSafely(lcpMap[lcpName]!, "NP1-2", row, startIdx + 10);
    _addNpSafely(lcpMap[lcpName]!, "NP3-4", row, startIdx + 11);
    _addNpSafely(lcpMap[lcpName]!, "NP5-6", row, startIdx + 12);
    _addNpSafely(lcpMap[lcpName]!, "NP7-8", row, startIdx + 13);
  }

  void _addNpSafely(Map<String, dynamic> lcpObj, String npName, List<dynamic> row, int colIndex) {
    if (colIndex >= row.length) return;
    String rawValue = row[colIndex].toString();
    if (rawValue.trim().isEmpty || rawValue.toUpperCase().contains("N/A")) return;

    // Cleaner: Replace non-numeric chars (except . and -) with space
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
      // Philippines Rough Bounds check
      if (lat > 4 && lat < 22 && lng > 116 && lng < 128) {
        lcpObj['nps'].add({'name': npName, 'lat': lat, 'lng': lng});
      }
    }
  }
}