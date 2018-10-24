## Cluster Pre-config hook
resource "null_resource" "icp-cluster-preconfig-hook" {
  count = "${contains(keys(var.hooks), "cluster-preconfig") ? var.cluster_size : 0}"

  connection {
    host         = "${element(local.icp-ips, count.index)}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # Run cluster-preconfig commands
  provisioner "remote-exec" {
    inline = [
      "${var.hooks["cluster-preconfig"]}",
    ]
  }
}

## Actions that has to be taken on all nodes in the cluster
resource "null_resource" "icp-cluster" {
  depends_on = ["null_resource.icp-cluster-preconfig-hook"]
  count      = "${var.cluster_size}"

  connection {
    host         = "${element(local.icp-ips, count.index)}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # Validate we can do passwordless sudo in case we are not root
  provisioner "remote-exec" {
    inline = [
      "sudo -n echo This will fail unless we have passwordless sudo access",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm",
      "subscription-manager repos --enable \"rhel-*-optional-rpms\" --enable \"rhel-*-extras-rpms\"",
      "yum install -y git aria2",
      "cd /tmp",
      "git clone https://github.com/se35710/terraform-module-icp-deploy.git",
      "chmod a+x /tmp/terraform-module-icp-deploy/scripts/common/*",
      "/tmp/terraform-module-icp-deploy/scripts/common/prereqs.sh",
      "/tmp/terraform-module-icp-deploy/scripts/common/version-specific.sh ${var.icp-version}",
      "/tmp/terraform-module-icp-deploy/scripts/common/docker-user.sh"
    ]
  }
}

## Cluster postconfig hook
resource "null_resource" "icp-cluster-postconfig-hook" {
  depends_on = ["null_resource.icp-cluster"]
  count      = "${contains(keys(var.hooks), "cluster-postconfig") ? var.cluster_size : 0}"

  connection {
    host         = "${element(local.icp-ips, count.index)}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # Run cluster-postconfig commands
  provisioner "remote-exec" {
    inline = [
      "${var.hooks["cluster-postconfig"]}",
    ]
  }
}

# First hook for Boot node
resource "null_resource" "icp-boot-preconfig" {
  depends_on = ["null_resource.icp-cluster-postconfig-hook", "null_resource.icp-cluster"]
  count      = "${contains(keys(var.hooks), "boot-preconfig") ? 1 : 0}"

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # Run stage hook commands
  provisioner "remote-exec" {
    inline = [
      "${var.hooks["boot-preconfig"]}",
    ]
  }
}

resource "null_resource" "icp-docker" {
  depends_on = ["null_resource.icp-boot-preconfig", "null_resource.icp-cluster"]

  count = "${var.parallell-image-pull ? var.cluster_size : "1"}"

  # Boot node is always the first entry in the IP list, so if we're not pulling in parallell this will only happen on boot node
  connection {
    host         = "${element(local.icp-ips, count.index)}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/ibm/cluster",
      "sudo chown ${var.ssh_user} /opt/ibm/cluster",
      "chmod a+x /tmp/terraform-module-icp-deploy/scripts/boot-master/*.sh",
      "/tmp/terraform-module-icp-deploy/scripts/boot-master/install-docker.sh \"${var.docker_package_location}\" "
    ]
  }
}

resource "null_resource" "icp-image" {
  depends_on = ["null_resource.icp-docker"]

  count = "${var.parallell-image-pull ? var.cluster_size : "1"}"

  # Boot node is always the first entry in the IP list, so if we're not pulling in parallell this will only happen on boot node
  connection {
    host         = "${element(local.icp-ips, count.index)}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # If this is enterprise edition we'll need to copy the image file over and load it in local repository
  // We'll need to find another workaround while tf does not support count for this
  provisioner "remote-exec" {
    inline = [
      "echo \"Loading image ${var.icp-version}\"",
      "/tmp/terraform-module-icp-deploy/scripts/boot-master/load-image.sh ${var.icp-version} /tmp/${basename(var.image_file)} \"${var.image_location}\" "
    ]
  }
}

# First make sure scripts and configuration files are copied
resource "null_resource" "icp-boot" {
  depends_on = ["null_resource.icp-image"]

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # store config yaml if it was specified
  provisioner "file" {
    content      = "${var.icp_config_file}"
    destination = "/tmp/config.yaml"
  }

  # JSON dump the contents of icp_configuration items
  provisioner "file" {
    content     = "${jsonencode(var.icp_configuration)}"
    destination = "/tmp/items-config.yaml"
  }
}

# Generate all necessary configuration files, load image files, etc
resource "null_resource" "icp-config" {
  depends_on = ["null_resource.icp-boot"]

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  provisioner "remote-exec" {
    inline = [
      "/tmp/terraform-module-icp-deploy/scripts/boot-master/copy_cluster_skel.sh ${var.icp-version}",
      "sudo chown ${var.ssh_user} /opt/ibm/cluster/*",
      "chmod 600 /opt/ibm/cluster/ssh_key",
      "python /tmp/terraform-module-icp-deploy/scripts/boot-master/load-config.py ${var.config_strategy}"
    ]
  }

  # Copy the provided or generated private key
  provisioner "file" {
    source     = "id_rsa"
    destination = "/opt/ibm/cluster/ssh_key"
  }

  # Since the file provisioner deals badly with empty lists, we'll create the optional management nodes differently
  # Later we may refactor to use this method for all node types for consistency
  provisioner "remote-exec" {
    inline = [
      "echo -n ${join(",", var.icp-master)} > /opt/ibm/cluster/masterlist.txt",
      "echo -n ${join(",", var.icp-proxy)} > /opt/ibm/cluster/proxylist.txt",
      "echo -n ${join(",", var.icp-worker)} > /opt/ibm/cluster/workerlist.txt",
      "echo -n ${join(",", var.icp-management)} > /opt/ibm/cluster/managementlist.txt"
    ]
  }

  # JSON dump the contents of icp-host-groups items
  provisioner "file" {
    content     = "${jsonencode(var.icp-host-groups)}"
    destination = "/tmp/icp-host-groups.json"
  }
}

# Generate the hosts files on the cluster
resource "null_resource" "icp-generate-hosts-files" {
  depends_on = ["null_resource.icp-config"]

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  provisioner "remote-exec" {
    inline = [
      "/tmp/terraform-module-icp-deploy/scripts/boot-master/generate_hostsfiles.sh"
    ]
  }
}

# Boot node hook
resource "null_resource" "icp-preinstall-hook" {
  depends_on = ["null_resource.icp-generate-hosts-files"]
  count      = "${contains(keys(var.hooks), "preinstall") ? 1 : 0}"

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # Run stage hook commands
  provisioner "remote-exec" {
    inline = [
      "${var.hooks["preinstall"]}",
    ]
  }
}

# Start the installer
resource "null_resource" "icp-install" {
  depends_on = ["null_resource.icp-preinstall-hook", "null_resource.icp-generate-hosts-files"]

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  provisioner "remote-exec" {
    inline = [
      "/tmp/terraform-module-icp-deploy/scripts/boot-master/start_install.sh ${var.icp-version} ${var.install-verbosity}"
    ]
  }
}

# Hook for Boot node
resource "null_resource" "icp-postinstall-hook" {
  depends_on = ["null_resource.icp-install"]
  count      = "${contains(keys(var.hooks), "postinstall") ? 1 : 0}"

  # The first master is always the boot master where we run provisioning jobs from
  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  # Run stage hook commands
  provisioner "remote-exec" {
    inline = [
      "${var.hooks["postinstall"]}"
    ]
  }
}

resource "null_resource" "icp-worker-scaler" {
  depends_on = ["null_resource.icp-cluster", "null_resource.icp-install"]

  triggers {
    workers = "${join(",", var.icp-worker)}"
  }

  connection {
    host         = "${local.boot-node}"
    user         = "${var.ssh_user}"
    private_key  = "${var.ssh_key}"
    agent        = "${var.ssh_agent}"
    bastion_host = "${var.bastion_host}"
  }

  provisioner "remote-exec" {
    inline = [
      "echo -n ${join(",", var.icp-master)} > /tmp/masterlist.txt",
      "echo -n ${join(",", var.icp-proxy)} > /tmp/proxylist.txt",
      "echo -n ${join(",", var.icp-worker)} > /tmp/workerlist.txt",
      "echo -n ${join(",", var.icp-management)} > /tmp/managementlist.txt"
    ]
  }

  # JSON dump the contents of icp-host-groups items
  provisioner "file" {
    content     = "${jsonencode(var.icp-host-groups)}"
    destination = "/tmp/scaled-host-groups.json"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod a+x /tmp/terraform-module-icp-deploy/scripts/boot-master/scaleworkers.sh",
      "/tmp/terraform-module-icp-deploy/scripts/boot-master/scaleworkers.sh ${var.icp-version}"
    ]
  }
}
