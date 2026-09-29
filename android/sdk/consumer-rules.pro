# Consumer R8/ProGuard rules for br.com.flowbiz:onsite-sdk, shipped in the AAR
# via consumerProguardFiles and applied to host-app release builds.
#
# Deliberately empty: the SDK uses no reflection, no JNI and no name-based
# (de)serialization (the wire format is built by hand with org.json), so R8
# keeps the public APIs the host references and may strip or rename the rest.
# If the SDK ever introduces any of those, or classes reached only via
# resources/manifest strings, the matching -keep rules MUST land here in the
# same change.
