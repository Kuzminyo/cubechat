// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.mockito.Mockito.any;
import static org.mockito.Mockito.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.hardware.camera2.CameraCharacteristics;
import android.util.SizeF;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.core.ZoomState;
import androidx.lifecycle.MutableLiveData;
import androidx.annotation.Nullable;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.UseCase;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Executor;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.mockito.MockedStatic;
import org.mockito.Mockito;
import org.mockito.stubbing.Answer;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class ProcessCameraProviderTest {
  @Test
  public void getInstance_returnsExpectedProcessCameraProviderInFutureCallback() {
    final PigeonApiProcessCameraProvider api =
        new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();

    final ProcessCameraProvider instance = mock(ProcessCameraProvider.class);
    final ListenableFuture<ProcessCameraProvider> processCameraProviderFuture =
        spy(Futures.immediateFuture(instance));

    try (MockedStatic<ProcessCameraProvider> mockedProcessCameraProvider =
            Mockito.mockStatic(ProcessCameraProvider.class);
        MockedStatic<ContextCompat> mockedContextCompat = Mockito.mockStatic(ContextCompat.class)) {
      mockedProcessCameraProvider
          .when(() -> ProcessCameraProvider.getInstance(any()))
          .thenAnswer(
              (Answer<ListenableFuture<ProcessCameraProvider>>)
                  invocation -> processCameraProviderFuture);

      mockedContextCompat
          .when(() -> ContextCompat.getMainExecutor(any()))
          .thenAnswer((Answer<Executor>) invocation -> mock(Executor.class));

      final ArgumentCaptor<Runnable> runnableCaptor = ArgumentCaptor.forClass(Runnable.class);

      final ProcessCameraProvider[] resultArray = {null};
      api.getInstance(
          ResultCompat.asCompatCallback(
              reply -> {
                resultArray[0] = reply.getOrNull();
                return null;
              }));

      verify(processCameraProviderFuture).addListener(runnableCaptor.capture(), any());
      runnableCaptor.getValue().run();
      assertEquals(resultArray[0], instance);
    }
  }

  @Test
  public void getAvailableCameraInfos_returnsExpectedCameraInfos() {
    final PigeonApiProcessCameraProvider api =
        new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();

    final ProcessCameraProvider instance = mock(ProcessCameraProvider.class);
    final List<CameraInfo> value = Collections.singletonList(mock(CameraInfo.class));
    when(instance.getAvailableCameraInfos()).thenReturn(value);

    assertEquals(value, api.getAvailableCameraInfos(instance));
  }

  @Test
  public void cameraChoices_preferActualFieldOfViewAndDoNotMutateProviderList() {
    final ProcessCameraProviderProxyApi api =
        (ProcessCameraProviderProxyApi) new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();
    final ProcessCameraProvider provider = mock(ProcessCameraProvider.class);
    final CameraInfo tele = mock(CameraInfo.class);
    final CameraInfo wide = mock(CameraInfo.class);
    final CameraInfo ultra = mock(CameraInfo.class);
    final List<CameraInfo> original = List.of(tele, wide, ultra);
    when(provider.getAvailableCameraInfos()).thenReturn(original);
    try (MockedStatic<Camera2CameraInfo> bridge = Mockito.mockStatic(Camera2CameraInfo.class)) {
      cameraMetadata(bridge, tele, 12, 6, 1);
      cameraMetadata(bridge, wide, 6, 6, 1);
      cameraMetadata(bridge, ultra, 3, 6, 1);
      assertEquals(List.of(ultra, wide, tele), api.getAvailableCameraInfos(provider));
      assertEquals(List.of(tele, wide, ultra), original);
    }
  }

  @Test
  public void logicalCameraMinimumZoomCountsTowardsItsFieldOfView() {
    final CameraInfo logical = mock(CameraInfo.class);
    final CameraInfo wide = mock(CameraInfo.class);
    try (MockedStatic<Camera2CameraInfo> bridge = Mockito.mockStatic(Camera2CameraInfo.class)) {
      cameraMetadata(bridge, logical, 6, 6, .5f);
      cameraMetadata(bridge, wide, 6, 6, 1);
      assertEquals(2.0, ProcessCameraProviderProxyApi.fieldOfViewScore(logical), .001);
      assertEquals(1.0, ProcessCameraProviderProxyApi.fieldOfViewScore(wide), .001);
    }
  }

  @Test
  public void missingMetadataPreservesAvailableCameraOrder() {
    final ProcessCameraProviderProxyApi api =
        (ProcessCameraProviderProxyApi) new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();
    final ProcessCameraProvider provider = mock(ProcessCameraProvider.class);
    final CameraInfo first = mock(CameraInfo.class);
    final CameraInfo second = mock(CameraInfo.class);
    when(provider.getAvailableCameraInfos()).thenReturn(List.of(first, second));
    try (MockedStatic<Camera2CameraInfo> bridge = Mockito.mockStatic(Camera2CameraInfo.class)) {
      bridge.when(() -> Camera2CameraInfo.from(first)).thenThrow(new IllegalArgumentException());
      bridge.when(() -> Camera2CameraInfo.from(second)).thenReturn(mock(Camera2CameraInfo.class));
      assertEquals(List.of(first, second), api.getAvailableCameraInfos(provider));
    }
  }

  private static void cameraMetadata(MockedStatic<Camera2CameraInfo> bridge,
      CameraInfo camera, float focal, float sensorShortEdge, float minimumZoom) {
    final Camera2CameraInfo info = mock(Camera2CameraInfo.class);
    bridge.when(() -> Camera2CameraInfo.from(camera)).thenReturn(info);
    when(info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE))
        .thenReturn(new SizeF(sensorShortEdge * 4 / 3, sensorShortEdge));
    when(info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS))
        .thenReturn(new float[] {focal});
    final ZoomState zoom = mock(ZoomState.class);
    when(zoom.getMinZoomRatio()).thenReturn(minimumZoom);
    when(camera.getZoomState()).thenReturn(new MutableLiveData<>(zoom));
  }

  @Test
  public void bindToLifecycle_callsBindToLifecycleWithSelectorsAndUseCases() {
    final PigeonApiProcessCameraProvider api =
        new TestProxyApiRegistrar() {
          @Nullable
          @Override
          public LifecycleOwner getLifecycleOwner() {
            return mock(LifecycleOwner.class);
          }
        }.getPigeonApiProcessCameraProvider();

    final ProcessCameraProvider instance = mock(ProcessCameraProvider.class);
    final androidx.camera.core.CameraSelector cameraSelector = mock(CameraSelector.class);
    final List<androidx.camera.core.UseCase> useCases =
        Collections.singletonList(mock(UseCase.class));
    final androidx.camera.core.Camera value = mock(Camera.class);
    when(instance.bindToLifecycle(
            any(), eq(cameraSelector), eq(useCases.toArray(new UseCase[] {}))))
        .thenReturn(value);

    assertEquals(value, api.bindToLifecycle(instance, cameraSelector, useCases));
  }

  @Test
  public void isBound_returnsExpectedIsBound() {
    final PigeonApiProcessCameraProvider api =
        new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();

    final ProcessCameraProvider instance = mock(ProcessCameraProvider.class);
    final androidx.camera.core.UseCase useCase = mock(UseCase.class);
    final Boolean value = true;
    when(instance.isBound(useCase)).thenReturn(value);

    assertEquals(value, api.isBound(instance, useCase));
  }

  @Test
  public void unbind_callsUnBindOnInstance() {
    final PigeonApiProcessCameraProvider api =
        new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();

    final ProcessCameraProvider instance = mock(ProcessCameraProvider.class);
    final List<androidx.camera.core.UseCase> useCases =
        Collections.singletonList(mock(UseCase.class));
    api.unbind(instance, useCases);

    verify(instance).unbind(useCases.toArray(new UseCase[] {}));
  }

  @Test
  public void unbindAll() {
    final PigeonApiProcessCameraProvider api =
        new TestProxyApiRegistrar().getPigeonApiProcessCameraProvider();

    final ProcessCameraProvider instance = mock(ProcessCameraProvider.class);
    api.unbindAll(instance);

    verify(instance).unbindAll();
  }
}
