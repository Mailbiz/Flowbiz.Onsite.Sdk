# Consumer R8/ProGuard rules for br.com.flowbiz:onsite-sdk (SPEC §13).
#
# Deliberately empty — audited 2026-07 against the full SDK source:
#
#   - No reflection: no Class.forName / kotlin.reflect / java.lang.reflect
#     lookups anywhere in main sources. (The only `::class.java` use is
#     CanonicalJson reading the runtime class of an in-hand object for an
#     exception message — R8-safe, no keep rule needed.)
#   - No JNI / native libraries: no System.loadLibrary, no .so files.
#   - No serialization-by-name: the wire format is built by hand with
#     org.json (EventSerializer/CanonicalJson); no Gson/Moshi/Jackson/
#     kotlinx.serialization, no @Keep-dependent annotation processing.
#   - No Parcelable/Serializable models, no AndroidManifest components
#     referenced by class name beyond what AGP/R8 keep automatically.
#
# Under those conditions R8 needs no help: public SDK APIs the host app
# references are kept automatically, and any unreferenced internals may be
# stripped or renamed harmlessly.
#
# When to add rules here: if the SDK ever introduces reflection, JNI,
# name-based (de)serialization, or classes reached only via resources/
# manifest strings, the corresponding -keep rules MUST land in this file in
# the same change (this file ships inside the AAR via consumerProguardFiles
# and is applied to host-app release builds automatically).
