import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tomato Detector',
      theme: ThemeData(
        primarySwatch: Colors.red,
      ),
      home: TomatoDetector(),
    );
  }
}

class TomatoDetector extends StatefulWidget {
  @override
  _TomatoDetectorState createState() => _TomatoDetectorState();
}

class _TomatoDetectorState extends State<TomatoDetector> {
  // --- VARIABEL UI & STATE ---
  File? _image;
  String _label = "Siap Scan";
  String _sizeLabel = "-";
  String _confString = "-";
  Color _statusColor = Colors.grey;

  // --- VARIABEL AI & LOGIC ---
  Interpreter? _interpreter;
  List<double> _scalerMean = [];
  List<double> _scalerScale = [];
  double _pixelPerCm = 0.0; // Dari camera_calib.json

  bool _isScalerLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadAllAssets();
  }

  // 1. FUNGSI LOAD SEMUA ASSET (Model + JSON)
  Future<void> _loadAllAssets() async {
    try {
      // A. Load Model TFLite
      _interpreter = await Interpreter.fromAsset('assets/tomato_model_2output.tflite');
      print("Model TFLite Loaded.");

      // B. Load Scaler Params
      String scalerString = await rootBundle.loadString('assets/scaler_params.json');
      final scalerData = jsonDecode(scalerString);
      _scalerMean = List<double>.from(scalerData['mean']);
      _scalerScale = List<double>.from(scalerData['scale']);
      _isScalerLoaded = true;
      print("Scaler Loaded: $_scalerMean");

      // C. Load Camera Calibration
      String calibString = await rootBundle.loadString('assets/camera_calib.json');
      final calibData = jsonDecode(calibString);
      // Ambil pixel_per_cm, default ke 0.0 jika gagal/null
      _pixelPerCm = (calibData['pixel_per_cm'] ?? 0.0).toDouble();
      print("Kalibrasi Loaded: $_pixelPerCm px/cm");

    } catch (e) {
      print("Error Loading Assets: $e");
      setState(() => _label = "Error Load Asset");
    }
  }

  // 2. FUNGSI PILIH GAMBAR
  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _label = "Memproses...";
        _statusColor = Colors.blue;
      });
      // Delay sedikit biar UI update dulu
      await Future.delayed(const Duration(milliseconds: 100));
      _processHybridLogic(_image!);
    }
  }

  // 3. FUNGSI HITUNG DIAMETER PIXEL (ALGORITMA SEDERHANA)
  // Scan garis tengah gambar untuk mencari tepi kiri dan kanan objek
  double _calculateDiameterPx(img.Image image) {
    int width = image.width;
    int height = image.height;
    int midY = height ~/ 2; 
    
    int leftX = -1;
    int rightX = -1;

    // Scan dari KIRI
    for (int x = 0; x < width; x++) {
      var pixel = image.getPixel(x, midY);
      // Cek kecerahan, jika agak gelap (< 250) berarti bukan background putih
      double brightness = (pixel.r + pixel.g + pixel.b) / 3.0;
      if (brightness < 250) { 
        leftX = x;
        break; 
      }
    }

    // Scan dari KANAN
    for (int x = width - 1; x >= 0; x--) {
      var pixel = image.getPixel(x, midY);
      double brightness = (pixel.r + pixel.g + pixel.b) / 3.0;
      if (brightness < 250) {
        rightX = x;
        break;
      }
    }

    if (leftX != -1 && rightX != -1 && rightX > leftX) {
      return (rightX - leftX).toDouble();
    }
    
    // Jika gagal deteksi, kembalikan 0 (atau lebar penuh sebagai fallback)
    return 0.0; 
  }

  // 4. FUNGSI HITUNG RATA-RATA HUE
  double _calculateMeanHue(img.Image image) {
    double totalHue = 0;
    int count = 0;
    // Sampling biar cepat, resize kecil dulu
    img.Image small = img.copyResize(image, width: 50, height: 50);
    for (var pixel in small) {
      totalHue += pixel.r; // Range 0-360
      count++;
    }
    return count == 0 ? 0 : totalHue / count;
  }

  // 5. LOGIKA UTAMA (PEMROSESAN)
  Future<void> _processHybridLogic(File imageFile) async {
    if (_interpreter == null || !_isScalerLoaded) {
      print("Model/Scaler belum siap.");
      return;
    }

    final bytes = await imageFile.readAsBytes();
    final img.Image? originalImage = img.decodeImage(bytes);
    if (originalImage == null) return;

    // --- A. DATA NUMERIK (Dihitung dari gambar ASLI) ---
    
    // 1. Hitung Ukuran Fisik
    double diameterPx = _calculateDiameterPx(originalImage);
    // Jika gagal deteksi, asumsi 80% lebar gambar
    if (diameterPx == 0) diameterPx = originalImage.width * 0.8;
    
    double areaPx = 3.14 * pow((diameterPx / 2), 2);
    
    // Hitung CM (jika ada kalibrasi)
    double diameterCm = 0.0;
    if (_pixelPerCm > 0) {
      diameterCm = diameterPx / _pixelPerCm;
    }

    // 2. Hitung Mean RGB (Perlu resize dulu biar ringan)
    img.Image resized = img.copyResize(originalImage, width: 128, height: 128);
    double sumR = 0, sumG = 0, sumB = 0;
    
    // Siapkan Buffer Gambar untuk Tensor sekalian looping
    var inputImageBuffer = Float32List(1 * 128 * 128 * 3);
    var bufferView = Float32List.view(inputImageBuffer.buffer);
    int pixelIndex = 0;

    for (var pixel in resized) {
      double r = pixel.r.toDouble();
      double g = pixel.g.toDouble();
      double b = pixel.b.toDouble();
      
      sumR += r; sumG += g; sumB += b;

      // Normalisasi MobileNet (-1 s/d 1)
      bufferView[pixelIndex++] = (r / 127.5) - 1.0;
      bufferView[pixelIndex++] = (g / 127.5) - 1.0;
      bufferView[pixelIndex++] = (b / 127.5) - 1.0;
    }

    double meanR = sumR / (128 * 128);
    double meanG = sumG / (128 * 128);
    double meanB = sumB / (128 * 128);

    // 3. FFT (Dummy Constant karena sulit hitung FFT akurat di HP tanpa library berat)
    // Nilai ini diambil rata-rata dari training data agar aman
    double dummyFFT = 10.5; 

    // 4. Gabungkan Fitur Numerik
    List<double> numericFeatures = [
      meanR, meanG, meanB, dummyFFT, diameterPx, areaPx
    ];

    // 5. Scaling (Normalisasi)
    var inputNumericBuffer = Float32List(1 * 6);
    for (int i = 0; i < 6; i++) {
      if (i < _scalerMean.length) {
         inputNumericBuffer[i] = (numericFeatures[i] - _scalerMean[i]) / _scalerScale[i];
      }
    }

    // --- B. JALANKAN INFERENCE AI ---
    
    // Siapkan Wadah Output (Sesuai Error [1,3] dan [1,1])
    // Output 0: Size (3 kelas)
    var outputSizeBuffer = Float32List(3).reshape([1, 3]);
    // Output 1: Ripeness (1 kelas)
    var outputRipenessBuffer = Float32List(1).reshape([1, 1]);

    Map<int, Object> outputs = {
      0: outputSizeBuffer,
      1: outputRipenessBuffer
    };

    // Jalankan Model (Ingat: Numeric DULU, baru Gambar)
    _interpreter!.runForMultipleInputs(
      [
        inputNumericBuffer.reshape([1, 6]), 
        inputImageBuffer.reshape([1, 128, 128, 3])
      ], 
      outputs
    );

    // --- C. AMBIL HASIL AI ---
    
    // 1. Hasil Ripeness
    var resRipenessList = outputs[1] as List;
    double ripenessRaw = resRipenessList[0][0] as double;

    // 2. Hasil Size
    var resSizeList = outputs[0] as List;
    List<double> sizeProbs = List<double>.from(resSizeList[0]);
    
    // Cari index probabilitas tertinggi
    int sizeIndex = 0;
    double maxScore = -1.0;
    for (int i = 0; i < sizeProbs.length; i++) {
      if (sizeProbs[i] > maxScore) {
        maxScore = sizeProbs[i];
        sizeIndex = i;
      }
    }
    String aiSizeLabel = (sizeIndex == 0) ? "KECIL" : (sizeIndex == 1) ? "SEDANG" : "BESAR";

    // --- D. LOGIKA FINAL (HYBRID) ---
    
    // Hitung Hue
    double meanHue = _calculateMeanHue(resized);
    double opencvHue = meanHue / 2.0; // Konversi ke skala 0-180

    String finalLabel;
    double finalConf;
    Color finalColor;

    // Logika Warna Hue (Hard Rule)
    if (opencvHue > 35 && opencvHue < 90) {
      finalLabel = "UNRIPE";
      finalConf = 1.0;
      finalColor = Colors.green;
    } else {
      // Logika AI
      // Jika output sigmoid < 0.5 anggap Unripe, > 0.5 anggap Ripe
      if (ripenessRaw < 0.5) {
        finalLabel = "UNRIPE";
        finalConf = 1.0 - ripenessRaw;
        finalColor = Colors.green;
      } else {
        finalLabel = "RIPE";
        finalConf = ripenessRaw;
        finalColor = Colors.red;
      }
    }

    // --- E. UPDATE UI ---
    String displaySize = "$aiSizeLabel";
    if (diameterCm > 0) {
      displaySize += "\n(${diameterCm.toStringAsFixed(1)} cm)";
    } else {
      displaySize += "\n(No Calib)";
    }

    setState(() {
      _label = finalLabel;
      _confString = "${(finalConf * 100).toStringAsFixed(1)}%";
      _statusColor = finalColor;
      _sizeLabel = displaySize;
    });
    
    print("Result: $finalLabel, Hue: $opencvHue, AI Raw: $ripenessRaw, Size: $aiSizeLabel");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deteksi Tomat Hybrid V6')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 1. Area Gambar
              if (_image != null)
                Container(
                  margin: const EdgeInsets.all(15),
                  height: 300,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 2),
                    image: DecorationImage(
                      image: FileImage(_image!),
                      fit: BoxFit.contain,
                    )
                  ),
                )
              else
                Container(
                  margin: const EdgeInsets.all(15),
                  height: 250,
                  width: 250,
                  color: Colors.grey[300],
                  child: const Center(
                    child: Icon(Icons.add_a_photo, size: 80, color: Colors.grey)
                  ),
                ),
              
              const SizedBox(height: 20),

              // 2. Hasil Deteksi Kematangan
              Text(
                _label,
                style: TextStyle(
                  fontSize: 42, 
                  fontWeight: FontWeight.bold, 
                  color: _statusColor
                ),
              ),
              Text(
                "Kepercayaan: $_confString",
                style: const TextStyle(fontSize: 18),
              ),

              const Divider(thickness: 2, height: 40, indent: 40, endIndent: 40),

              // 3. Hasil Deteksi Ukuran
              const Text("Ukuran:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text(
                _sizeLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, color: Colors.blueGrey, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 40),
              
              // 4. Tombol
              ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.camera_alt),
                label: const Text("Ambil Gambar"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}