const MAX_DIMENSION = 512;
const TARGET_BYTES = 200 * 1024;
const QUALITY_STEPS = [0.8, 0.6, 0.4];
const PRE_COMPRESS_LIMIT = 10 * 1024 * 1024;

export async function compressImage(file: File): Promise<string> {
  if (!file.type.startsWith("image/")) {
    throw new Error("画像ファイルを選んでください");
  }
  if (file.size > PRE_COMPRESS_LIMIT) {
    throw new Error("ファイルが大きすぎます（10MBまで）");
  }

  const bitmap = await createImageBitmap(file);
  const { width: bw, height: bh } = bitmap;
  const scale = Math.min(1, MAX_DIMENSION / Math.max(bw, bh));
  const w = Math.max(1, Math.round(bw * scale));
  const h = Math.max(1, Math.round(bh * scale));

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (!ctx) {
    bitmap.close();
    throw new Error("Canvas が利用できません");
  }
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close();

  for (const q of QUALITY_STEPS) {
    const dataUrl = await canvasToJpegDataUrl(canvas, q);
    if (estimateBase64Bytes(dataUrl) <= TARGET_BYTES) return dataUrl;
  }
  throw new Error("画像サイズを200KB以下に圧縮できませんでした");
}

function canvasToJpegDataUrl(canvas: HTMLCanvasElement, quality: number): Promise<string> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (!blob) return reject(new Error("画像のエンコードに失敗しました"));
        const reader = new FileReader();
        reader.onerror = () => reject(reader.error ?? new Error("読み込みエラー"));
        reader.onload = () => resolve(String(reader.result));
        reader.readAsDataURL(blob);
      },
      "image/jpeg",
      quality
    );
  });
}

function estimateBase64Bytes(dataUrl: string): number {
  const i = dataUrl.indexOf(",");
  const b64 = i >= 0 ? dataUrl.slice(i + 1) : dataUrl;
  const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.floor((b64.length * 3) / 4) - padding;
}
