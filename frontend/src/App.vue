<script>
import timezonesTxt from './assets/timezones.txt?raw';
import {nextTick, provide, ref} from "vue";

export default {
  data() {
    return {
      error_message: "",
      subprocesses: {},
      block_devices: [],
      install_to_device_process_key: "",
      install_to_device_status: "",
      has_nvidia: false,
      want_nvidia: false,
      overall_status: "",
      running: false,
      finished: false,
      output_reader_connection: null,
      timezones: [],
      ram_gb: 0,
      suggested_swap_gb: 0,
      
      // password handling
      user_password: "",
      user_password_confirm: "",
      use_same_password: false,
      
      // values for the installer:
      installer: {
        DISK: undefined,
        USERNAME: undefined,
        USER_FULL_NAME: undefined,
        USER_PASSWORD: undefined,
        ROOT_PASSWORD: undefined,
        ENCRYPTION_PASSWORD: undefined,
        ENABLE_ENCRYPTION: false,
        ENABLE_TPM: undefined,
        HOSTNAME: undefined,
        TIMEZONE: undefined,
        SWAP_SIZE: undefined,
        NVIDIA_PACKAGE: " ",  // will be changed in install()
        ENABLE_POPCON: undefined,
        ENABLE_UBUNTU_THEME: false,
        ENABLE_SUDO: false,
        DISABLE_ROOT: false,
        SSH_PUBLIC_KEY: undefined,
        AFTER_INSTALLED_CMD: undefined,
      }
    }
  },
  computed: {
    can_start() {
      let ret = true;
      if(this.error_message.length>0) {
        ret = false;
      }
      // Check password validation first
      if (!this.has_valid_password) {
        ret = false;
      }
      
      // Check sudo is enabled if root is disabled
      if (this.installer.DISABLE_ROOT && !this.installer.ENABLE_SUDO) {
        ret = false;
      }
      
      // Check required fields
      for(const [key, value] of Object.entries(this.installer)) {
        if(key === "ENCRYPTION_PASSWORD" && !this.installer.ENABLE_ENCRYPTION) {
          continue;
        }
        if(key === "USER_PASSWORD" || key === "ROOT_PASSWORD") {
          continue; // Handled by password validation above
        }
        if(key === "NVIDIA_PACKAGE") {
          continue; // Optional
        }
        if(key === "ENABLE_UBUNTU_THEME" || key === "ENABLE_POPCON" || key === "ENABLE_TPM" || key === "ENABLE_SUDO" || key === "DISABLE_ROOT") {
          continue; // Optional checkboxes
        }
        if(typeof value === 'undefined' || value === null || value === "") {
          if(key !== "SSH_PUBLIC_KEY" && key !== "AFTER_INSTALLED_CMD") {
            ret = false;
            break;
          }
        }
      }
      return ret;
    },
    missing_fields() {
      let missing = [];
      if(this.error_message.length > 0) {
        return ['Error: ' + this.error_message];
      }
      
      // Check password validation
      if (!this.user_password) {
        missing.push('Password');
      } else if (!this.passwords_match) {
        missing.push('Password confirmation (passwords must match)');
      }
      
      // Check sudo requirement when root is disabled
      if (this.installer.DISABLE_ROOT && !this.installer.ENABLE_SUDO) {
        missing.push('Sudo access (required when root account is disabled)');
      }
      
      for(const [key, value] of Object.entries(this.installer)) {
        if(key === "ENCRYPTION_PASSWORD" && !this.installer.ENABLE_ENCRYPTION) {
          continue;
        }
        if(key === "USER_PASSWORD" || key === "ROOT_PASSWORD") {
          continue; // Handled by password validation above
        }
        if(key === "NVIDIA_PACKAGE" || key === "ENABLE_UBUNTU_THEME" || key === "ENABLE_POPCON" || key === "ENABLE_TPM" || key === "ENABLE_SUDO" || key === "DISABLE_ROOT") {
          continue; // Optional
        }
        if(typeof value === 'undefined' || value === null || value === "") {
          if(key !== "SSH_PUBLIC_KEY" && key !== "AFTER_INSTALLED_CMD") {
            let fieldName = key.toLowerCase().replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
            missing.push(fieldName);
          }
        }
      }
      return missing;
    },
    hostname() {
      return window.location.hostname;
    },
    
    passwords_match() {
      return this.user_password === this.user_password_confirm;
    },
    
    has_valid_password() {
      return this.user_password.length >= 3 && this.passwords_match;
    }
  },
  setup() {
    provide('singlePasswordActive', ref(false));
    provide('singlePasswordValue', ref(""));
  },
  mounted() {
    this.get_available_timezones();
    this.check_login();
  },
  methods: {
    check_login() {
      this.fetch_from_backend("/login")
        .then(response => {
          if(!response.has_efi) {
            this.error_message = "This system does not appear to use EFI. This installer will not work."
          } else {
            this.error_message = "";
          }
          if(response.running) {
            this.running = true;
            this.finished = false;
          } else {
            this.running = false;
          }
          this.has_nvidia = response.has_nvidia;
          this.want_nvidia = response.has_nvidia;
          
          // Store RAM info and auto-fill swap size
          this.ram_gb = response.ram_gb || 0;
          this.suggested_swap_gb = response.suggested_swap_gb || 2;
          if(response.suggested_swap_gb && this.installer.SWAP_SIZE === undefined) {
            this.installer.SWAP_SIZE = response.suggested_swap_gb;
          }

          for(const [key, value] of Object.entries(this.installer)) {
            if(key in response.environ) {
              if(key === "NVIDIA_PACKAGE" && response.environ[key] === "") {
                continue; // because empty value would prevent can_start()
              } else if(key === "NVIDIA_PACKAGE" && response.environ[key].length > 0) {
                this.want_nvidia = true;
                this.has_nvidia = true;
              }
              console.debug(`Setting '${key}' from backend to '${response.environ[key]}'`);
              this.installer[key] = response.environ[key];
            }
          }
          
          this.get_block_devices();
          this.read_process_output();

        })
        .catch((error) => {
          this.error_message = "Backend not yet available";
          console.info("Backend not yet available");
          console.error(error);
          setTimeout(this.check_login, 1000);
        });
    },
    get_block_devices() {
      this.fetch_from_backend("/block_devices")
          .then(response => {
            console.debug(response);
            this.block_devices = response.blockdevices;
            for(const device of this.block_devices) {
              device.in_use = false;
              if(device.mountpoint) {
                device.in_use = true;
              }
              if("children" in device) {
                for (const child of device.children) {
                  if (child.mountpoint) {
                    device.in_use = true;
                  }
                }
              }
              if(device.size === "0B") {
                device.ro = true;
              }
              if(device.ro || device.in_use) {
                device.available = false;
              } else {
                device.available = true;
              }
            }
          }); // TODO check errors
    },
    get_available_timezones() {
      for(const line of timezonesTxt.split("\n")) {
        if(line.startsWith("#")) {
          continue;
        }
        this.timezones.push(line);
      }
    },
    read_process_output() {
      this.output_reader_connection = new WebSocket(`ws://${this.hostname}:5000/process_output`);
      this.output_reader_connection.onmessage = (event) => {
        // console.log("Websocket event received");
        // console.log(event);
        this.install_to_device_status += event.data.toString();
        nextTick(() => {
          this.$refs.process_output_ta.scrollTop = 1000000;
        });
        // console.log(this.install_to_device_status);
      }
      this.output_reader_connection.onclose = (event) => {
        console.log("Websocket connection closed");
        this.check_process_status();
      }
    },
    install() {
      this.running = true;
      
      // Ensure passwords are set before installation
      if (this.use_same_password || !this.installer.USER_PASSWORD) {
        this.installer.USER_PASSWORD = this.user_password;
      }
      if (this.use_same_password || !this.installer.ROOT_PASSWORD) {
        this.installer.ROOT_PASSWORD = this.user_password;
      }
      if (this.installer.ENABLE_ENCRYPTION && (this.use_same_password || !this.installer.ENCRYPTION_PASSWORD)) {
        this.installer.ENCRYPTION_PASSWORD = this.user_password;
      }
      
      if(this.installer["NVIDIA_PACKAGE"] !== " ") {
        // we received a package name from the back-end, nothing to do here
      } else if(this.want_nvidia) {
        this.installer["NVIDIA_PACKAGE"] = "nvidia-driver";
      } else {
        this.installer["NVIDIA_PACKAGE"] = "";
      }
      let data = new FormData();
      for(const [key, value] of Object.entries(this.installer)) {
        data.append(key, value);
      }
      fetch(`http://${this.hostname}:5000/install`, {"method": "POST", "body": data})
        .then(response => {
            //console.debug(response);
            if(!response.ok) {
                throw Error(response.statusText);
            }
            return response.json();
        })
        .then(result => {
            console.debug(result);
            this.finished = false;
            
        })
        .catch(error => {
            this.running = false;
            // TODO set this.error_message
            throw Error(error);
        });
    },
    check_process_status() {
      this.fetch_from_backend("/process_status")
          .then(response => {
            console.debug(response);
            this.install_to_device_status = response.output;
            if(response.status == "FINISHED") {
              this.running = false;
              this.finished = true;
              if (response.return_code == 0) {
                this.overall_status = "green";
                this.$refs.completed_dialog.showModal();
              } else {
                this.overall_status = "red";
              }
            }
          }); // TODO error checking
    },
    clear() {
      this.fetch_from_backend("/clear")
          .then(response => {
            console.log(response);
            this.install_to_device_status = "";
            this.overall_status = "";
            this.finished = false;
            this.running = false;
          })
          .catch(error => {
            // TODO set this.error_message
            throw Error(error);
          });
    },
    fetch_from_backend(path) {
      let url = new URL(path, `http://${this.hostname}:5000`);
      return fetch(url.href)
          .then(response => {
            if(!response.ok) {
              // console.error(response);
              throw Error(response.statusText);
            }
            return response.json();
          })
          .catch(error => {
            // console.error(error);
            // TODO set this.error_message
            throw Error(error);
          });
    },
    
    updatePasswordsFromMain() {
      if (this.use_same_password && this.user_password) {
        this.installer.USER_PASSWORD = this.user_password;
        this.installer.ROOT_PASSWORD = this.user_password;
        if (this.installer.ENABLE_ENCRYPTION) {
          this.installer.ENCRYPTION_PASSWORD = this.user_password;
        }
      }
    },
    
    toggleSamePassword() {
      if (this.use_same_password) {
        this.updatePasswordsFromMain();
      }
    }
  },
  
  watch: {
    user_password() {
      if (this.use_same_password) {
        this.updatePasswordsFromMain();
      }
    },
    
    use_same_password() {
      this.toggleSamePassword();
    },
    
    'installer.ENABLE_ENCRYPTION'() {
      if (this.use_same_password) {
        this.updatePasswordsFromMain();
      }
    },
    
    'installer.DISABLE_ROOT'() {
      // Force sudo when root is disabled
      if (this.installer.DISABLE_ROOT) {
        this.installer.ENABLE_SUDO = true;
      }
    }
  }
}
</script>
<template>
  <img alt="banner" class="logo" src="@/assets/Ceratopsian_installer.svg" />

  <header>
    <h1>Opinionated Debian Installer</h1>
    <p>
      This is an <strong>unofficial</strong> installer for the Debian GNU/Linux operating system.
      For more information, read the <a href="https://github.com/r0b0/debian-installer">project page</a>.
    </p>
    <h2>Instructions</h2>
    <ul>
      <li>The installer <strong>will overwrite the entire disk</strong>.</li>
      <li>I repeat, <strong>your entire disk will be overwritten</strong> when you press the Install button.
        There is no way to undo this action.</li>
      <li>If you encounter issues, press the <em>Stop</em> button, open a terminal and investigate.</li>
      <li>Password for the root user in this live system is <code>live</code></li>
      <li>Data in this live system will be persisted, this is not read-only.</li>
    </ul>
    <h2>Features</h2>
    <ul>
      <li>Backports and non-free enabled</li>
      <li>Firmware installed</li>
      <li>Installed on ZFS datasets with boot environment management via zectl</li>
      <li>Optional ZFS native encryption (AES-256-GCM)</li>
      <li>Fast installation using an image</li>
      <li>Browser-based installer</li>
    </ul>
  </header>

  <main>
    <form>
      <div class="red">{{error_message}}</div>
      <fieldset>
        <legend>Installation Target Device</legend>
        <label for="DISK">Device for Installation</label>
        <select :disabled="block_devices.length==0 || running" id="DISK"  v-model="installer.DISK">
          <option v-for="item in block_devices" :value="item.path" :disabled="!item.available">
            {{item.path}} {{item.model}} {{item.size}} {{item.ro ? '(Read Only)' : ''}} {{item.in_use ? '(In Use)' : ''}}
          </option>
        </select>
        <label for="DEBIAN_VERSION">Debian Version</label>
        <select id="DEBIAN_VERSION">
          <option value="trixie" selected>Debian 13 Trixie</option>
        </select>
      </fieldset>

      <fieldset>
        <legend>ZFS Native Encryption</legend>
        <input type="checkbox" v-model="installer.ENABLE_ENCRYPTION" id="ENABLE_ENCRYPTION" class="inline">
        <label for="ENABLE_ENCRYPTION" class="inline">Enable ZFS native encryption</label>

        <Password v-if="installer.ENABLE_ENCRYPTION" v-model="installer.ENCRYPTION_PASSWORD" :disabled="running" :is-main="true"/>
      </fieldset>

      <fieldset>
        <legend>Password Setup</legend>
        <label for="user_password">Password</label>
        <input type="password" id="user_password" v-model="user_password" :disabled="running" placeholder="Enter password">
        
        <label for="user_password_confirm">Confirm Password</label>
        <input type="password" id="user_password_confirm" v-model="user_password_confirm" :disabled="running" placeholder="Confirm password">
        
        <div v-if="user_password && !passwords_match" class="password-error">
          Passwords do not match!
        </div>
        
        <br>
        <input type="checkbox" v-model="use_same_password" id="use_same_password" class="inline mt-3" :disabled="running">
        <label for="use_same_password" class="inline mt-3">Use same password for everything (user, root, and encryption if enabled)</label>
      </fieldset>

      <fieldset>
        <legend>User Account</legend>
        <label for="USERNAME">User Name</label>
        <input type="text" id="USERNAME" v-model="installer.USERNAME" :disabled="running">
        <label for="full_name">Full Name</label>
        <input type="text" id="USER_FULL_NAME" v-model="installer.USER_FULL_NAME" :disabled="running">
        
        <br>
        <input type="checkbox" v-model="installer.DISABLE_ROOT" id="DISABLE_ROOT" class="inline mt-3" :disabled="running">
        <label for="DISABLE_ROOT" class="inline mt-3">Disable root account (more secure)</label>
        
        <br>
        <input type="checkbox" v-model="installer.ENABLE_SUDO" id="ENABLE_SUDO" class="inline mt-3" :disabled="running" :required="installer.DISABLE_ROOT">
        <label for="ENABLE_SUDO" class="inline mt-3">Add user to sudo group (allows admin access)</label>
        <small v-if="installer.DISABLE_ROOT" class="sudo-required">
          Required when root account is disabled
        </small>
      </fieldset>

      <fieldset>
        <legend>Configuration</legend>
        <label for="HOSTNAME">Hostname</label>
        <input type="text" id="HOSTNAME" v-model="installer.HOSTNAME" :disabled="running">

        <label for="TIMEZONE">Time Zone</label>
        <select :disabled="timezones.length==0 || running" id="TIMEZONE" v-model="installer.TIMEZONE">
            <option v-for="item in timezones" :value="item">{{ item }}</option>
        </select>

        <label for="SWAP_SIZE">Swap Size (GB)</label>
        <input type="number" id="SWAP_SIZE" v-model="installer.SWAP_SIZE" :disabled="running">
        <small v-if="ram_gb > 0" class="swap-suggestion">
          Detected {{ ram_gb }}GB RAM, suggested: {{ suggested_swap_gb }}GB swap
        </small>

        <input type="checkbox" v-model="want_nvidia" id="WANT_NVIDIA" class="inline mt-3" :disabled="!has_nvidia || running">
        <label for="WANT_NVIDIA" class="inline mt-3">Install the proprietary NVIDIA Accelerated Linux Graphics Driver</label>

        <br>
        <input type="checkbox" v-model="installer.ENABLE_POPCON" id="ENABLE_POPCON" class="inline mt-3" :disabled="running">
        <label for="ENABLE_POPCON" class="inline mt-3">Participate in the <a href="https://popcon.debian.org/" target="_blank">debian package usage survey</a></label>

        <br>
        <input type="checkbox" v-model="installer.ENABLE_UBUNTU_THEME" id="ENABLE_UBUNTU_THEME" class="inline mt-3" :disabled="running">
        <label for="ENABLE_UBUNTU_THEME" class="inline mt-3">Apply Ubuntu-like theme (Yaru theme, fonts, and GNOME extensions)</label>
      </fieldset>

      <fieldset>
        <legend>Process</legend>
        
        <div v-if="!can_start && missing_fields.length > 0" class="validation-message">
          <p><strong>Please fill in the following required fields:</strong></p>
          <ul>
            <li v-for="field in missing_fields" :key="field">{{ field }}</li>
          </ul>
        </div>
        
        <button type="button" @click="install()"
                :disabled="!can_start || running">
            Install debian on {{ installer.DISK }} <b>OVERWRITING THE WHOLE DRIVE</b>
        </button>
        <br>
        <button type="button" @click="clear()" class="mt-2 red">Stop</button>
      </fieldset>

      <fieldset>
        <legend>Process Output</legend>
        <textarea ref="process_output_ta" :class="overall_status">{{ install_to_device_status }}</textarea>

        <!-- TODO disable this while not finished instead of hiding -->
        <a v-if="finished" :href="'http://' + hostname + ':5000/download_log'" download>Download Log</a>
      </fieldset>
    </form>
  </main>

  <footer>
    <span>Opinionated Debian Installer version 20250722a</span>
    <span>Installer &copy;2022-2025 <a href="https://github.com/r0b0/debian-installer">Robert T</a></span>
    <span>Banner &copy;2024 <a href="https://github.com/pccouper/trixie">Elise Couper</a></span>
  </footer>

  <dialog ref="completed_dialog">
    <p>
      Debian successfully installed. You can now turn off your computer, remove the installation media and start it again.
    </p>
    <button class="right-align mt-2" @click="$refs.completed_dialog.close()">Close</button>
  </dialog>
</template>

<style>
@import './assets/base.css';

#app {
  max-width: 1280px;
  margin: 0 auto;
  padding: 2rem;

  font-weight: normal;
}

header {
  line-height: 1.5;
}

.logo {
  display: block;
  width: 100%;
  padding-bottom: 12pt;
  grid-area: logo;
}

a,
.green {
  text-decoration: none;
  color: #26475b;
  transition: 0.4s;
}

.red {
  color: #cd130f;
}

input:not(.inline), select, textarea {
  width: 100%;
}

textarea {
  height: 20em;
}

label:not(.inline) {
  display: block;
}

.mt-2 {
  margin-top: 0.5em;
}

.mt-3 {
  margin-top: 1em;
}

.right-align {
  float: right;
}

@media (hover: hover) {
  a:hover {
    background-color: hsla(160, 100%, 37%, 0.2);
  }
}

.validation-message {
  background-color: #fff3cd;
  border: 1px solid #ffeaa7;
  border-radius: 4px;
  padding: 12px;
  margin: 10px 0;
  color: #856404;
}

.validation-message p {
  margin: 0 0 8px 0;
  font-weight: bold;
}

.validation-message ul {
  margin: 0;
  padding-left: 20px;
}

.validation-message li {
  margin: 4px 0;
}

.swap-suggestion {
  display: block;
  color: #666;
  font-style: italic;
  margin-top: 4px;
  font-size: 0.9em;
}

.password-error {
  background-color: #ffebee;
  border: 1px solid #f44336;
  border-radius: 4px;
  padding: 8px;
  margin: 4px 0;
  color: #c62828;
  font-size: 0.9em;
}

.sudo-required {
  display: block;
  color: #d32f2f;
  font-style: italic;
  margin-top: 4px;
  font-size: 0.9em;
  font-weight: bold;
}

@media (min-width: 1024px) {
  body {
    display: flex;
    place-items: center;
  }

  #app {
    display: grid;
    grid-template-columns: 1fr 1fr;
    grid-template-areas:
        "logo logo"
        "header main"
        "footer footer";
    padding: 0 2rem;
  }

  .logo {
    margin: 0 2rem 0 0;
  }

  h1 {
    margin-top: 0;
  }

  footer {
    margin-top: 2em;
    grid-area: footer;
    justify-self: center;
  }
}

footer span {
  margin-right: 2em;
}
</style>
