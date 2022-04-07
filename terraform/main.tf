terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "swarm-node-count" {
  type    = string
  default = "2"
}

variable "admin-name" {
  type    = string
  default = "adminswarm"

}

data "http" "my_ip" {
  url = "http://ifconfig.me/ip"
}

data "azurerm_client_config" "current" {}

resource "random_id" "random-name" {
  byte_length = 4
}

resource "azurerm_key_vault" "test" {
  name                       = "kv-test${lower(random_id.random-name.hex)}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enabled_for_deployment     = "true"
  enable_rbac_authorization  = "false"
  purge_protection_enabled   = "false"

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  depends_on = []
}

resource "azurerm_key_vault_access_policy" "kv-test-access-policy" {
  key_vault_id = azurerm_key_vault.test.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Get",
    "Import",
    "List",
  ]

  secret_permissions = [
    "List",
    "Get",
    "Set",
  ]
}

# Create (and display) an SSH key
resource "tls_private_key" "ssh-cluster-swarm" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_key_vault_secret" "ssh-pub-key" {
  name         = "ssh-cluster-pub-key"
  value        = tls_private_key.ssh-cluster-swarm.public_key_openssh
  key_vault_id = azurerm_key_vault.test.id

  depends_on = [azurerm_key_vault.test]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "ssh-priv-key" {
  name         = "ssh-cluster-priv-key"
  value        = tls_private_key.ssh-cluster-swarm.private_key_pem
  key_vault_id = azurerm_key_vault.test.id

  depends_on = [azurerm_key_vault.test]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-techblog"
  location = "Central US"
}

resource "azurerm_network_security_group" "test" {
  name                = "nsg-techblog-swarmCluster"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "nsg-rule-ssh-mgmt" {
  name                        = "ssh-mmgmt"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       =  "${chomp(data.http.my_ip.body)}/32"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.test.name
}

resource "azurerm_subnet_network_security_group_association" "nsg-rule" {
  subnet_id                 = azurerm_subnet.test.id
  network_security_group_id = azurerm_network_security_group.test.id
}

resource "azurerm_virtual_network" "test" {
  name                = "vnet-techblog-cidr"
  address_space       = ["172.31.255.0/24"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "test" {
  name                 = "acctsub"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = ["172.31.255.64/27"]
}

resource "azurerm_public_ip" "test" {
  name                = "publicIP-LB"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Basic"
}

resource "azurerm_lb" "test" {
  name                = "loadBalancer"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Basic"

  frontend_ip_configuration {
    name                 = "publicIPAddress"
    public_ip_address_id = azurerm_public_ip.test.id
  }
}

resource "azurerm_lb_backend_address_pool" "test" {
  loadbalancer_id = azurerm_lb.test.id
  name            = "Backend"
}


resource "azurerm_public_ip" "mgmt-vm" {
  count               = var.swarm-node-count
  name                = "publicIp-techblog${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Basic"
}

resource "azurerm_network_interface" "test" {
  count               = var.swarm-node-count
  name                = "acctni${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig0"
    subnet_id                     = azurerm_subnet.test.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = element(azurerm_public_ip.mgmt-vm.*.id, count.index)
  }
}

resource "azurerm_availability_set" "avset" {
  name                         = "avset"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
  managed                      = true
}

resource "azurerm_managed_disk" "test" {
  count                = var.swarm-node-count
  name                 = "datadisk_existing_${count.index}"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = "64"
}

# Create storage account for boot diagnostics
resource "azurerm_storage_account" "test" {
  name                     = "stgdiag${lower(random_id.random-name.hex)}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_linux_virtual_machine" "test" {
  count                           = var.swarm-node-count
  name                            = "techblog${count.index}"
  location                        = azurerm_resource_group.rg.location
  availability_set_id             = azurerm_availability_set.avset.id
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = "Standard_B2s"
  admin_username                  = var.admin-name
  disable_password_authentication = true

  network_interface_ids = [
    element(azurerm_network_interface.test.*.id, count.index)
  ]

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  os_disk {
    name                 = "myosdisk${count.index}"
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  admin_ssh_key {
    username   = var.admin-name
    public_key = azurerm_key_vault_secret.ssh-pub-key.value
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.test.primary_blob_endpoint
  }

  tags = {
    role        = "Swarm Cluster"
    environment = "Tech Blog"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "test" {
  count              = var.swarm-node-count
  managed_disk_id    = element(azurerm_managed_disk.test.*.id, count.index)
  virtual_machine_id = element(azurerm_linux_virtual_machine.test.*.id, count.index)
  lun                = count.index
  caching            = "ReadWrite"
}