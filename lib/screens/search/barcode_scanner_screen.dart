import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../utils/app_snack.dart';

/// True when [code] is a book barcode: a 13-digit EAN starting with
/// 978/979, i.e. an ISBN-13. Anything else (other EAN prefixes, QR
/// codes, ISBN-10) is not a book barcode.
@visibleForTesting
bool isBookBarcode(String code) =>
    RegExp(r'^97[89]\d{10}$').hasMatch(code.trim());

/// Full-screen ISBN barcode scanner (扫码搜书).
///
/// Opens the camera, reads EAN-13 barcodes and pops with the ISBN-13
/// when the barcode starts with 978/979 (the book prefixes). A barcode
/// that is not a book barcode shows a toast and keeps scanning.
class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final _controller = MobileScannerController();

  /// A valid ISBN was already read: ignore further detections so the
  /// page pops exactly once.
  bool _handled = false;

  /// Last time a non-book barcode was reported: throttles the toast so
  /// a held-up non-book barcode does not spam it.
  DateTime? _lastInvalidAt;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    if (capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    // Book barcodes are EAN-13 starting with 978/979; the 13 digits
    // are the ISBN-13.
    if (isBookBarcode(code)) {
      _handled = true;
      if (mounted) Navigator.of(context).pop(code);
      return;
    }
    final now = DateTime.now();
    if (_lastInvalidAt != null &&
        now.difference(_lastInvalidAt!).inSeconds < 2) {
      return;
    }
    _lastInvalidAt = now;
    if (mounted) {
      showAppSnack(context, AppLocalizations.of(context)!.notBookBarcode);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scanBarcode)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.cameraUnavailable,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          // Scan frame + hint overlay: aim the barcode at the frame.
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 280,
                height: 170,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  l10n.scanBarcodeHint,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
