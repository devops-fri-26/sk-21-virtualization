Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.hostname = "bookstack"

  config.vm.network "forwarded_port",
    guest: 80,
    host: 8080,
    host_ip: "127.0.0.1"
  config.vm.network "forwarded_port",
    guest: 443,
    host: 8443,
    host_ip: "127.0.0.1"
    # Netdata monitoring
  config.vm.network "forwarded_port",
    guest: 19999,
    host: 19999,
    host_ip: "127.0.0.1"

  config.vm.provider "virtualbox" do |vb|
    vb.name = "bookstack-vm"
    vb.memory = 2048
    vb.cpus = 2
  end
  config.vm.provision "shell", path: "scripts/install.sh"
end