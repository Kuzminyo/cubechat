// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.util.Range;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.video.VideoCapture;
import androidx.camera.core.MirrorMode;
import androidx.camera.video.VideoOutput;

/**
 * ProxyApi implementation for {@link VideoCapture}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class VideoCaptureProxyApi extends PigeonApiVideoCapture {
  VideoCaptureProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  // Range<?> is defined as Range<Integer> in pigeon.
  @SuppressWarnings("unchecked")
  @NonNull
  @Override
  public VideoCapture<?> withOutput(
      @NonNull VideoOutput videoOutput, @Nullable Range<?> targetFpsRange) {
    VideoCapture.Builder<VideoOutput> builder = new VideoCapture.Builder<>(videoOutput);
    // Match the selfie preview in the recorded file. CameraX applies this per
    // lens, including sensor changes in a persistent circle recording.
    builder.setMirrorMode(MirrorMode.MIRROR_MODE_ON_FRONT_ONLY);

    if (targetFpsRange != null) {
      // Use CameraX negotiation so unsupported 60 fps falls back to a viable
      // device rate, also when a persistent recording changes cameras.
      builder.setTargetFrameRate((Range<Integer>) targetFpsRange);
    }

    return builder.build();
  }

  @NonNull
  @Override
  public VideoOutput getOutput(VideoCapture<?> pigeonInstance) {
    return pigeonInstance.getOutput();
  }

  @Override
  public void setTargetRotation(VideoCapture<?> pigeonInstance, long rotation) {
    pigeonInstance.setTargetRotation((int) rotation);
  }
}
