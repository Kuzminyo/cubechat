import 'dart:io';

import 'package:flutter/material.dart';

/// The flight between a photo in a conversation and the same photo full screen.
///
/// Both ends draw the same file and neither draws it the same way: a bubble
/// crops the picture to its own box (`cover`), the viewer fits the whole of it
/// inside the screen (`contain`). Flutter's default shuttle is the
/// *destination's* child, so the flight used to begin by drawing a contained,
/// letterboxed photo inside a bubble-sized rectangle — the picture jumped out
/// of its crop the instant it was touched, and only then started moving. The
/// jump is what read as broken; the movement after it was always fine.
///
/// Crossing the two fits over the course of the flight makes the crop appear to
/// open instead of cut. At either end the shuttle is exactly what that end
/// draws by itself, so there is nothing to snap to when the flight lands.
///
/// The pictures here are deliberately uncapped: this is one image for the
/// length of one flight, at up to full-screen size, and a `cacheWidth` sized
/// for the bubble would fly a thumbnail into a screen-filling frame and land on
/// something sharper.
HeroFlightShuttleBuilder photoFlightShuttle(String path) {
  return (flightContext, animation, direction, fromContext, toContext) {
    // Opening runs the animation forwards; closing runs the same crossing
    // backwards, so the picture crops itself back into the bubble rather than
    // uncropping on the way home.
    final t = direction == HeroFlightDirection.push
        ? animation
        : ReverseAnimation(animation);
    final curved = CurvedAnimation(parent: t, curve: Curves.easeInOut);
    final file = File(path);
    return Stack(
      fit: StackFit.expand,
      children: [
        FadeTransition(
          opacity: ReverseAnimation(curved),
          child: Image.file(file, fit: BoxFit.cover),
        ),
        FadeTransition(
          opacity: curved,
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ],
    );
  };
}
