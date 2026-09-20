# Sign-in guide artwork

Five approved, simplified instructional reference screens. All account details are fictional. The QR-like pattern is labeled SAMPLE and contains no authentication link. The outlined number is an example; instructions require the user's own code.

Editable SVG sources and their Python standard-library generator are preserved here. They are not bundle resources. To redraw: `python3 draw-illustrations.py`. To rasterize the SVG files: run `node render-assets.cjs` with sharp 0.35.4 available. The renderer writes 1600px-wide PNG assets under the shared guide asset catalog; sharp strips metadata by default. Native SwiftUI provides the headings, navigation, and accessible instructions.

The illustrations intentionally use stable light/dark panels matching the reference flow. They contain no live controls or sign-in behavior.
