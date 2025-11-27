import 'dart:io';
import 'dart:typed_data';
import 'dart:convert'; // Untuk membaca JSON
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // Untuk akses folder assets
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
  // --- VARIABEL UTAMA ---
  File? _image;
  String _label = "Siap Scan";
  String _sizeLabel = "-";
  String _confString = "-";
  Color _statusColor = Colors.grey;
  Interpreter? _interpreter;

  // --- VARIABEL UNTUK SCALER (JSON) ---
  List<double> _scalerMean = [];
  List<double> _scalerScale = [];
  bool _isScalerLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadModel();   // Muat otak AI (.tflite)
    _loadScaler();  // Muat data normalisasi (.json)
  }

  // 1. Fungsi Memuat File JSON Scaler
  Future<void> _loadScaler() async {
    try {
      String jsonString = await rootBundle.loadString('assets/scaler_params.json');
      final jsonData = jsonDecode(jsonString);

      setState(() {
        _scalerMean = List<double>.from(jsonData['mean']);
        _scalerScale = List<double>.from(jsonData['scale']);
        _isScalerLoaded = true;
      });
      print("Scaler loaded sukses: $_scalerMean");
    } catch (e) {
      print("Gagal load scaler JSON: $e");
      // Fallback nilai dummy agar aplikasi tidak crash
      _scalerMean = [0, 0, 0, 0, 0, 0];
      _scalerScale = [1, 1, 1, 1, 1, 1];
    }
  }

  // 2. Fungsi Memuat Model TFLite
  Future<void> _loadModel() async {
    try {
      // Pastikan nama file sesuai dengan yang ada di folder assets
      _interpreter = await Interpreter.fromAsset('tomato_model_2output.tflite');
      print("Model TFLite loaded.");
    } catch (e) {
      print("Gagal load model TFLite: $e");
    }
  }

  // 3. Fungsi Memilih Gambar
  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _label = "Memproses...";
        _statusColor = Colors.blue;
      });
      // Beri sedikit delay agar UI sempat update status "Memproses..."
      await Future.delayed(const Duration(milliseconds: 100));
      _processHybridLogic(_image!);
    }
  }

  // 4. LOGIKA UTAMA (Hybrid Hue + AI Multi Input)
  Future<void> _processHybridLogic(File imageFile) async {
    if (_interpreter == null) {
      setState(() => _label = "Model belum siap");
      return;
    }
    if (!_isScalerLoaded) {
      setState(() => _label = "Scaler JSON belum siap");
      return;
    }

    final bytes = await imageFile.readAsBytes();
    final img.Image? originalImage = img.decodeImage(bytes);
    if (originalImage == null) return;

    // --- A. PREPROCESSING GAMBAR (Input 1) ---
    // Resize ke 128x128 sesuai Python v6
    img.Image resized = img.copyResize(originalImage, width: 128, height: 128);
    
    // Siapkan buffer untuk Input Tensor [1, 128, 128, 3]
    var inputImage = Float32List(1 * 128 * 128 * 3);
    var buffer = Float32List.view(inputImage.buffer);
    int pixelIndex = 0;
    
    double sumR = 0, sumG = 0, sumB = 0;

    for (var pixel in resized) {
      double r = pixel.r.toDouble();
      double g = pixel.g.toDouble();
      double b = pixel.b.toDouble();
      
      sumR += r; sumG += g; sumB += b;

      // Normalisasi MobileNet (-1 s/d 1)
      buffer[pixelIndex++] = (r / 127.5) - 1.0;
      buffer[pixelIndex++] = (g / 127.5) - 1.0;
      buffer[pixelIndex++] = (b / 127.5) - 1.0;
    }

    // Hitung rata-rata RGB untuk Input Numerik
    double meanR = sumR / (128 * 128);
    double meanG = sumG / (128 * 128);
    double meanB = sumB / (128 * 128);

    // --- B. PREPROCESSING NUMERIK (Input 2) ---
    // Fitur: [MeanR, MeanG, MeanB, FFT, Diameter, Area]
    // FFT, Diameter, Area sulit dihitung akurat di HP tanpa OpenCV.
    // Kita pakai nilai ESTIMASI/DUMMY agar input tensor tetap valid (lengkap 6 angka).
    
    double dummyFFT = 10.0; 
    double estimatedDiameterPx = 100.0; // Asumsi tomat memenuhi tengah gambar
    double estimatedAreaPx = (3.14 * (50 * 50)); 

    List<double> numericFeatures = [
      meanR, meanG, meanB, dummyFFT, estimatedDiameterPx, estimatedAreaPx
    ];

    // Lakukan Scaling menggunakan data dari JSON
    var inputNumeric = Float32List(1 * 6);
    for (int i = 0; i < 6; i++) {
      // Rumus: (Value - Mean) / Scale
      inputNumeric[i] = (numericFeatures[i] - _scalerMean[i]) / _scalerScale[i];
    }

    // --- C. JALANKAN INFERENCE ---
    // Siapkan output buffer (hanya 1 angka: Ripeness Probability)
    var outputBuffer = Float32List(1);
    Map<int, Object> outputs = {0: outputBuffer.reshape([1, 1])};

    // Jalankan dengan 2 Input
    _interpreter!.runForMultipleInputs(
      [inputImage.reshape([1, 128, 128, 3]), inputNumeric.reshape([1, 6])], 
      outputs
    );

    double ripenessRaw = (outputs[0] as List)[0][0] as double; 
    print("Raw AI Prediction: $ripenessRaw");

    // --- D. LOGIKA WARNA (HUE) ---
    double meanHue = _calculateMeanHue(resized); 
    // Konversi Hue Dart (0-360) ke OpenCV (0-180) agar threshold sama
    double opencvHue = meanHue / 2.0; 

    // --- E. KEPUTUSAN FINAL (HYBRID) ---
    String finalLabel;
    double finalConf;
    Color finalColor;

    // Logika persis dari Python:
    if (opencvHue > 35 && opencvHue < 90) {
      // Hard Rule: Jika dominan Hijau -> Pasti UNRIPE
      finalLabel = "UNRIPE";
      finalConf = 1.0;
      finalColor = Colors.green; 
    } else {
      // Jika tidak Hijau, percaya pada skor AI
      if (ripenessRaw > 0.5) {
        finalLabel = "UNRIPE";
        finalConf = ripenessRaw;
        finalColor = Colors.green;
      } else {
        finalLabel = "RIPE";
        finalConf = 1.0 - ripenessRaw;
        finalColor = Colors.red;
      }
    }

    // Estimasi ukuran (Placeholder)
    String sizeRes = (estimatedDiameterPx < 150) ? "SMALL" : "LARGE";

    // Update UI
    setState(() {
      _label = finalLabel;
      _confString = "${(finalConf * 100).toStringAsFixed(1)}%";
      _statusColor = finalColor;
      _sizeLabel = sizeRes;
    });
  }

  // Helper: Hitung Hue Rata-rata
  double _calculateMeanHue(img.Image image) {
    double totalHue = 0;
    int count = 0;
    // Loop pixel image
    for (var pixel in image) {
      totalHue += pixel.r; // Range 0-360
      count++;
    }
    return count == 0 ? 0 : totalHue / count;
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
              // Tampilan Gambar
              if (_image != null)
                Container(
                  margin: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 2),
                  ),
                  child: Image.file(_image!, height: 250, fit: BoxFit.cover),
                )
              else
                Container(
                  height: 250,
                  width: 250,
                  color: Colors.grey[300],
                  child: const Icon(Icons.image, size: 100, color: Colors.grey),
                ),
              
              const SizedBox(height: 30),

              // Tampilan Hasil
              Text(
                _label,
                style: TextStyle(
                  fontSize: 40, 
                  fontWeight: FontWeight.bold, 
                  color: _statusColor
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "Kepercayaan: $_confString",
                style: const TextStyle(fontSize: 20),
              ),
              Text(
                "Ukuran (Est): $_sizeLabel",
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),

              const SizedBox(height: 40),
              
              // Tombol Ambil Gambar
              ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.camera_alt),
                label: const Text("Ambil Gambar dari Galeri"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}