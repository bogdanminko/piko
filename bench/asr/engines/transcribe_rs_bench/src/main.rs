//! transcribe-rs benchmark runner (meetily-style usage).
//!
//! Single-file mode:   transcribe_rs_bench <model.bin> <audio.wav> [lang]
//!   → one JSON line: {engine, load_s, transcribe_s, text}
//! Whisper batch mode: transcribe_rs_bench --batch <model.bin> <lang> <wav>...
//!   → meta line {load_s}, then one line per file: {file, transcribe_s, text}
//!   (model loaded once for the whole batch)
//! Parakeet batch:     transcribe_rs_bench --parakeet-batch <model_dir> <wav>...
//!   → same output shape as whisper batch mode. Loads the ONNX Parakeet
//!   engine (CoreML execution provider via the `ort-coreml` feature) from
//!   `model_dir` (expects encoder-model.onnx, decoder_joint-model.onnx,
//!   nemo128.onnx, vocab.txt — the istupakov/parakeet-tdt-0.6b-v3-onnx layout).

use std::env;
use std::path::PathBuf;
use std::time::Instant;
use transcribe_rs::onnx::parakeet::ParakeetModel;
use transcribe_rs::onnx::Quantization;
use transcribe_rs::whisper_cpp::WhisperEngine;
use transcribe_rs::{SpeechModel, TranscribeOptions};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() >= 2 && args[1] == "--batch" {
        batch(&args[2..]);
    } else if args.len() >= 2 && args[1] == "--parakeet-batch" {
        parakeet_batch(&args[2..]);
    } else {
        single(&args[1..]);
    }
}

fn parakeet_batch(args: &[String]) {
    if args.len() < 2 {
        eprintln!("usage: transcribe_rs_bench --parakeet-batch <model_dir> <wav>...");
        std::process::exit(2);
    }
    let model_dir = PathBuf::from(&args[0]);
    let files = &args[1..];

    let t0 = Instant::now();
    let mut model =
        ParakeetModel::load(&model_dir, &Quantization::FP32).expect("model load failed");
    let load_s = t0.elapsed().as_secs_f64();
    println!("{}", serde_json::json!({ "meta": true, "load_s": load_s }));

    let opts = TranscribeOptions::default();
    for f in files {
        let t1 = Instant::now();
        let result = model
            .transcribe_file(&PathBuf::from(f), &opts)
            .expect("transcription failed");
        let transcribe_s = t1.elapsed().as_secs_f64();
        println!(
            "{}",
            serde_json::json!({ "file": f, "transcribe_s": transcribe_s, "text": result.text })
        );
    }
}

fn batch(args: &[String]) {
    if args.len() < 3 {
        eprintln!("usage: transcribe_rs_bench --batch <model.bin> <lang> <wav>...");
        std::process::exit(2);
    }
    let model_path = PathBuf::from(&args[0]);
    let lang = args[1].clone();
    let files = &args[2..];

    let t0 = Instant::now();
    let mut engine = WhisperEngine::load(&model_path).expect("model load failed");
    let load_s = t0.elapsed().as_secs_f64();
    println!("{}", serde_json::json!({ "meta": true, "load_s": load_s }));

    let opts = TranscribeOptions {
        language: Some(lang),
        ..Default::default()
    };
    for f in files {
        let t1 = Instant::now();
        let result = engine
            .transcribe_file(&PathBuf::from(f), &opts)
            .expect("transcription failed");
        let transcribe_s = t1.elapsed().as_secs_f64();
        println!(
            "{}",
            serde_json::json!({ "file": f, "transcribe_s": transcribe_s, "text": result.text })
        );
    }
}

fn single(args: &[String]) {
    if args.len() < 2 {
        eprintln!("usage: transcribe_rs_bench <model.bin> <audio.wav> [lang]");
        std::process::exit(2);
    }
    let model_path = PathBuf::from(&args[0]);
    let audio_path = PathBuf::from(&args[1]);
    let lang = args.get(2).cloned();

    let t0 = Instant::now();
    let mut engine = WhisperEngine::load(&model_path).expect("model load failed");
    let load_s = t0.elapsed().as_secs_f64();

    let opts = TranscribeOptions {
        language: lang,
        ..Default::default()
    };
    let t1 = Instant::now();
    let result = engine
        .transcribe_file(&audio_path, &opts)
        .expect("transcription failed");
    let transcribe_s = t1.elapsed().as_secs_f64();

    println!(
        "{}",
        serde_json::json!({
            "engine": "transcribe-rs",
            "load_s": load_s,
            "transcribe_s": transcribe_s,
            "text": result.text,
            "n_segments": result.segments.as_ref().map(|s| s.len()),
        })
    );
}
