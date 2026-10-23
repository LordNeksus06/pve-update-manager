# Put first on @INC to make "require JSON::XS" fail, so code that prefers
# JSON::XS falls back to JSON::PP - the backend of a machine without
# libjson-xs-perl. See the "JSON backends" block in tests/run-tests.sh (#50).
die "JSON::XS is hidden for this run\n";
