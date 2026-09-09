// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.hardware.camera2.CameraCharacteristics;
import android.util.SizeF;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.UseCase;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.List;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * ProxyApi implementation for {@link ProcessCameraProvider}. This class may handle instantiating
 * native object instances that are attached to a Dart instance or handle method calls on the
 * associated native class or an instance of that class.
 */
@OptIn(markerClass = ExperimentalCamera2Interop.class)
class ProcessCameraProviderProxyApi extends PigeonApiProcessCameraProvider {
  ProcessCameraProviderProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @Override
  public void getInstance(
      @NonNull Function1<? super Result<ProcessCameraProvider>, Unit> callback) {
    final ListenableFuture<ProcessCameraProvider> processCameraProviderFuture =
        ProcessCameraProvider.getInstance(getPigeonRegistrar().getContext());

    processCameraProviderFuture.addListener(
        () -> {
          try {
            // Camera provider is now guaranteed to be available.
            ResultCompat.success(processCameraProviderFuture.get(), callback);
          } catch (InterruptedException | ExecutionException e) {
            ResultCompat.failure(e, callback);
          }
        },
        ContextCompat.getMainExecutor(getPigeonRegistrar().getContext()));
  }

  @NonNull
  @Override
  public List<CameraInfo> getAvailableCameraInfos(ProcessCameraProvider pigeonInstance) {
    // CameraX descriptions reach Dart with lensType=unknown. Keep camera IDs
    // bound to their CameraInfo, but order the choices by usable field of view
    // so CircleRecorder's first lens is not an arbitrary (possibly tele) lens.
    // Only cameras CameraX actually exposes are considered, never hidden IDs.
    final List<CameraInfo> cameras = new ArrayList<>(pigeonInstance.getAvailableCameraInfos());
    final Map<CameraInfo, Double> fields = new HashMap<>();
    for (CameraInfo camera : cameras) fields.put(camera, fieldOfViewScore(camera));
    cameras.sort(Comparator.comparingDouble((CameraInfo camera) -> fields.get(camera)).reversed());
    return cameras;
  }

  static double fieldOfViewScore(CameraInfo camera) {
    try {
      final Camera2CameraInfo info = Camera2CameraInfo.from(camera);
      final SizeF sensor = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE);
      final float[] focal = info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
      if (sensor == null || focal == null || focal.length == 0 || focal[0] <= 0) return 0;
      // tan(FOV/2): comparing ratios needs no atan. The short sensor edge is
      // the width of a portrait circle. Account for logical cameras that can
      // zoom out across physical sensors, preserving their seamless switching.
      final androidx.camera.core.ZoomState zoom =
          camera.getZoomState() == null ? null : camera.getZoomState().getValue();
      final double minimum = zoom == null ? 1 : zoom.getMinZoomRatio();
      return Math.min(sensor.getWidth(), sensor.getHeight()) / focal[0]
          / (minimum > 0 ? minimum : 1);
    } catch (IllegalArgumentException | IllegalStateException ignored) {
      // External/non-Camera2 cameras and incomplete vendor metadata keep their
      // original relative order. Missing metadata must never prevent capture.
      return 0;
    }
  }

  @NonNull
  @Override
  public Camera bindToLifecycle(
      @NonNull ProcessCameraProvider pigeonInstance,
      @NonNull CameraSelector cameraSelector,
      @NonNull List<? extends UseCase> useCases) {
    final LifecycleOwner lifecycleOwner = getPigeonRegistrar().getLifecycleOwner();
    if (lifecycleOwner != null) {
      return pigeonInstance.bindToLifecycle(
          lifecycleOwner, cameraSelector, useCases.toArray(new UseCase[0]));
    }

    throw new IllegalStateException(
        "LifecycleOwner must be set to get ProcessCameraProvider instance.");
  }

  @Override
  public boolean isBound(ProcessCameraProvider pigeonInstance, @NonNull UseCase useCase) {
    return pigeonInstance.isBound(useCase);
  }

  @Override
  public void unbind(
      ProcessCameraProvider pigeonInstance, @NonNull List<? extends UseCase> useCases) {
    pigeonInstance.unbind(useCases.toArray(new UseCase[0]));
  }

  @Override
  public void unbindAll(ProcessCameraProvider pigeonInstance) {
    pigeonInstance.unbindAll();
  }
}
