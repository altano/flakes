# Recipients for every secret here. Two, and only two: the machine, so it can
# decrypt at activation, and alan, so these can be re-encrypted from a laptop.
#
# The machine's key is an age identity its host delivers to
# /run/agenix/owner-age-identity. Its public half lives with that host's
# config, and is copied here because a recipient list has to be readable
# without it.
let
  dumbunz = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn5yOADB+BHi3H2zYx4P6A4zsVqrhMJpSA3FKdDYYcM";
  alan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHzWY7ZSnlszb0sO42PREJeZGUlZdZlyXQG/JiJKGu9Y";
  all = [
    dumbunz
    alan
  ];
in
{
  "syncthing-cert.age".publicKeys = all;
  "syncthing-key.age".publicKeys = all;
}
