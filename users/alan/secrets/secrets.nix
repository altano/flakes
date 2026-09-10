# Recipients for every secret in this directory. The first is the age
# identity papa delivers to dumbunz at /run/agenix/owner-age-identity;
# the rest are the people who may re-encrypt them.
let
  dumbunz = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn5yOADB+BHi3H2zYx4P6A4zsVqrhMJpSA3FKdDYYcM";
  owner = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHzWY7ZSnlszb0sO42PREJeZGUlZdZlyXQG/JiJKGu9Y";
in
{
  "syncthing-key.age".publicKeys = [ dumbunz owner ];
}
