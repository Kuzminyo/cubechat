from __future__ import annotations

import argparse
import subprocess
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


FFMPEG = Path(
    r"D:\projects\cubechat\.tools\imageio_ffmpeg\imageio_ffmpeg\binaries"
    r"\ffmpeg-win-x86_64-v7.1.exe"
)
WORK_DIR = Path(r"D:\projects\cubechat\video_edit_work")


@dataclass(frozen=True)
class VideoJob:
    slug: str
    source: Path


JOBS = (
    VideoJob(
        "01_porozhnii_server",
        Path(r"C:\Users\kuzme\Downloads\«Порожній_сервер»_—_удар_по_ар.mp4"),
    ),
    VideoJob(
        "02_susidy",
        Path(r"C:\Users\kuzme\Downloads\«Сусіди»_—_тёплый_контрапункт.mp4"),
    ),
    VideoJob(
        "03_khto_dyvytsia",
        Path(r"C:\Users\kuzme\Downloads\«Хто_дивиться»_—_про_ротацию_и.mp4"),
    ),
    VideoJob(
        "04_vymknit_use",
        Path(r"C:\Users\kuzme\Downloads\«Вимкніть_усе»_—_эскалация_Луч.mp4"),
    ),
    VideoJob(
        "05_lantsiuh",
        Path(r"C:\Users\kuzme\Downloads\«Ланцюг»_—_сообщение_несут_чуж.mp4"),
    ),
)


def extract_samples() -> None:
    sample_dir = WORK_DIR / "samples"
    sample_dir.mkdir(parents=True, exist_ok=True)

    for job in JOBS:
        capture = cv2.VideoCapture(str(job.source))
        if not capture.isOpened():
            raise RuntimeError(f"Could not open {job.source}")

        fps = capture.get(cv2.CAP_PROP_FPS)
        width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
        target_width = 360 if height > width else 640
        target_height = round(height * target_width / width)
        if target_height % 2:
            target_height += 1

        wanted_frames = {
            round(t * fps): index for index, t in enumerate((1, 3, 5, 7, 9), start=1)
        }
        frame_index = 0
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            if frame_index in wanted_frames:
                sample_index = wanted_frames[frame_index]
                sample = cv2.resize(
                    frame,
                    (target_width, target_height),
                    interpolation=cv2.INTER_AREA,
                )
                destination = sample_dir / f"{job.slug}_{sample_index}.jpg"
                if not cv2.imwrite(
                    str(destination),
                    sample,
                    (cv2.IMWRITE_JPEG_QUALITY, 48),
                ):
                    raise RuntimeError(f"Could not write {destination}")
            frame_index += 1
        capture.release()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--samples",
        action="store_true",
        help="Extract compact reference frames at 1, 3, 5, 7, and 9 seconds.",
    )
    args = parser.parse_args()

    if args.samples:
        extract_samples()
        return
    parser.error("Choose an operation.")


if __name__ == "__main__":
    main()
