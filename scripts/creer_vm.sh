#!/bin/bash

image=/var/lib/libvirt/images/resolute-server-cloudimg-amd64.img
disque=/var/lib/libvirt/images/vm-auto.qcow2

if [ ! -f cloud-init/user-data ] || [ ! -f cloud-init/meta-data ]; then
    echo "Fichiers cloud-init introuvables, lancer le script depuis la racine du depot"
    exit 1
fi

if [ ! -f "$image" ]; then
    echo "Image cloud introuvable : $image"
    exit 1
fi

if virsh dominfo vm-auto > /dev/null 2>&1; then
    echo "La VM vm-auto existe deja, la supprimer avant de relancer"
    exit 1
fi

sudo cp "$image" "$disque"
sudo qemu-img resize "$disque" 10G

virt-install \
  --name vm-auto \
  --memory 1024 \
  --vcpus 1 \
  --disk "$disque" \
  --import \
  --osinfo linux2024 \
  --network network=default \
  --cloud-init user-data=cloud-init/user-data,meta-data=cloud-init/meta-data \
  --graphics none \
  --noautoconsole

echo "VM creee, attendre 1 a 2 minutes que cloud-init termine"
