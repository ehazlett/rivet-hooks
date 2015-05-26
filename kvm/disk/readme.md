# KVM Disk Image
This is a KVM provisioning plugin using a local disk image instead of
Boot2Docker.  This assumes you have a base image that you specify in the
`BASE_DISK` environment variable.  This base image should have SSH enabled
with the ability to pass a privileged user and password using the `SSH_USER`
and `SSH_PASS` variables to the Docker Machine Rivet driver.  It also must
use a supported base operating system by Machine.  See the Docker Machine docs
for details.
