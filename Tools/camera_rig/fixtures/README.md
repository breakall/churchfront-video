# Preview person fixture

`public-domain-person.jpg` is the official 2013 portrait of President Barack Obama, photographed by Pete Souza. It is used only as deterministic person-shaped input for the opt-in local UI tracking test; no identity recognition or endorsement is implied.

- Official source and low-resolution download: [Archived White House biography](https://obamawhitehouse.archives.gov/administration/president-obama), [original JPEG](https://obamawhitehouse.archives.gov/sites/whitehouse.gov/files/images/Administration/People/president_official_portrait_lores.jpg).
- Public-domain/reuse basis: the [Barack Obama Presidential Library's audiovisual guidance](https://www.obamalibrary.gov/digital-research-room/audiovisual-records) identifies its linked archived White House photographs as public-domain resources requiring no permission or licensing, with source credit requested.
- Credit: Official White House Photo by Pete Souza; courtesy Barack Obama Presidential Library.
- Downloaded November 24, 2026; original low-resolution bytes, 599 × 748 pixels, 303,258 bytes.
- SHA-256: `7c04a5d36eadf0ba43c2245ca1fc8edd399aba9c3e0b689391078f1933d93c26`.

On this Mac, the existing Apple Vision requests used by Churchfront (`VNDetectHumanBodyPoseRequest` and upper-body `VNDetectHumanRectanglesRequest`) found one body pose and one rectangle; the nose confidence was approximately 0.804. This establishes useful fixture input, not tracking accuracy or performance acceptance.

The static image does not change in response to simulated PTZ motion. Use it to exercise the actual app's tracking activation, command path, manual takeover and UI state changes, not to evaluate closed-loop tracking quality.
