# Exercise 1: Your first hardened machine

You'll run two Ubuntu machines on your Mac. One is left exactly as Ubuntu ships
it. The other sets itself up with a first-boot script (cloud-init). Then you'll
inspect both and try to get into them.

This is the whole project in miniature:

| In this exercise | In the real project |
|---|---|
| `plain` VM | a stock Lambda Stack instance |
| `hardened` VM + `cloud-init.yaml` | your secure inference image |
| `look-around.sh` | the audit script that produces your before/after numbers |
| Step 6 (try to get in) | the attack demo |

**What you'll learn:** SSH with keys, what "listening on a port" means, what a
firewall does, how security updates work, and how cloud-init configures a
machine on first boot.

**Time:** about an hour. **Cost:** free; everything runs on your Mac.

## Files

- `cloud-init.yaml`: the first-boot script, with every line commented
- `look-around.sh`: inspects a machine and prints PASS/WARN for a few checks
- `README.md`: this guide

Run every command below from this folder, in a Mac terminal.

## Before you start

You need two things:

1. **Multipass**, Canonical's tool for running Ubuntu VMs.

   ```bash
   multipass version
   ```

   If that fails, install it (it asks for your Mac password):

   ```bash
   brew install --cask multipass
   ```

2. **An SSH key.** This is a pair of files: a private key that never leaves
   your Mac, and a public key you hand out to machines you want to log into.

   ```bash
   ls ~/.ssh/id_ed25519.pub
   ```

   If that file doesn't exist, make a key (press Enter to accept the defaults):

   ```bash
   ssh-keygen -t ed25519
   ```

## Step 1: Launch a plain machine

```bash
multipass launch 24.04 --name plain
```

This downloads Ubuntu 24.04 the first time, so it takes a few minutes. Your Mac
has an Apple chip, so this is the ARM version of Ubuntu. The security ideas are
identical to the x86 machines on Lambda.

## Step 2: Look around it

Copy the script in and run it:

```bash
multipass transfer look-around.sh plain:
```

```bash
multipass exec plain -- sudo bash look-around.sh
```

Read the output top to bottom. Save it, because you'll compare it in step 5:

```bash
multipass exec plain -- sudo bash look-around.sh > plain-results.txt
```

**Things to notice:**

- **"Who can log in":** accounts with a real shell. Everything else is a system
  account that programs run as.
- **"Network":** each line is a program waiting for connections, with the
  address and port it listens on. `0.0.0.0` or `*` means "anyone who can reach
  this machine". `127.0.0.1` means "only programs on this machine".
- **"Firewall is off":** nothing stands between the network and those programs.

## Step 3: Read the cloud-init file

Open `cloud-init.yaml` and read it. Every line is commented. There are four
parts:

1. **users:** creates a `learner` account that can only log in with your SSH key.
2. **packages:** installs updates and two security tools.
3. **write_files:** drops in config files that lock down SSH and turn on daily
   security updates.
4. **runcmd:** turns on the firewall, allowing only SSH in.

## Step 4: Launch the hardened machine

The file has a placeholder where your public key goes. This makes a copy with
your key filled in:

```bash
sed "s|__SSH_PUBLIC_KEY__|$(cat ~/.ssh/id_ed25519.pub)|" cloud-init.yaml > my-cloud-init.yaml
```

Launch with it. It installs updates on first boot, so allow up to 15 minutes:

```bash
multipass launch 24.04 --name hardened --cloud-init my-cloud-init.yaml --timeout 900
```

## Step 5: Look around again and compare

```bash
multipass transfer look-around.sh hardened:
```

```bash
multipass exec hardened -- sudo bash look-around.sh > hardened-results.txt
```

```bash
diff plain-results.txt hardened-results.txt
```

Lines starting with `<` are from `plain`, and lines starting with `>` are from
`hardened`.

**Roughly what to expect:** `plain` ends with about `4 PASS, 3 WARN` (root
login allowed, firewall off, pending security updates). `hardened` ends with
about `8 PASS, 1 WARN`. The exact update counts change as Ubuntu releases fixes.

**The one WARN left on `hardened`:**

- **"Outgoing traffic is unrestricted":** blocking outbound traffic is the big
  one for an inference server, and it's the next exercise.

**You might also see "Waiting for a reboot":** if the updates included a new
kernel, the old one keeps running until a restart. Fix it and re-run the script:

```bash
multipass restart hardened
```

## Step 6: Try to get in

First, find each machine's IP address:

```bash
multipass list
```

### 6a. SSH with your key

Replace `HARDENED_IP` with the address from `multipass list`:

```bash
ssh learner@HARDENED_IP
```

The first time, SSH shows a fingerprint and asks whether to trust it. That's
SSH asking whether this is really the machine you meant. Type `yes`, then
`exit` to leave.

### 6b. SSH as root, and SSH with a password

```bash
ssh root@HARDENED_IP
```

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password learner@HARDENED_IP
```

Both should say `Permission denied (publickey)`. The machine doesn't even offer
a password prompt.

### 6c. A program that shouldn't be reachable

This is the "one door in" rule. You'll start a small web server on each machine
and try to reach it from your Mac. Use two terminal windows.

**Window 1** (inside the plain machine):

```bash
multipass shell plain
```

```bash
python3 -m http.server 8080
```

**Window 2** (on your Mac). Replace `PLAIN_IP`:

```bash
curl --max-time 5 http://PLAIN_IP:8080
```

You get a directory listing: anyone on the network can reach that program.
Press Ctrl-C in window 1, type `exit`, then repeat with the hardened machine:

```bash
multipass shell hardened
```

```bash
python3 -m http.server 8080
```

```bash
curl --max-time 5 http://HARDENED_IP:8080
```

This time `curl` gives up after 5 seconds. The program is running, but the
firewall drops the connection before it gets there.

Bonus: while the server is still running on `hardened`, run `look-around.sh`
again from a third window. It now flags port 8080.

## Step 7: Write down what you learned

Answering these is the first draft of your threat model:

1. How many programs were listening on the network on `plain`? Which ones?
2. What did the firewall change, and what did it **not** change? Hint: think
   about traffic leaving the machine.
3. Why is "no password at all" safer than "a strong password" for SSH?
4. An inference server only needs one port open, for the gateway. Which `ufw`
   commands would you change to allow only that?
5. `package_upgrade` installed updates at boot. What happens to updates
   released next month? Which part of the file handles that?

## If something goes wrong

- **Did cloud-init finish, and did it hit errors?**

  ```bash
  multipass exec hardened -- cloud-init status --long
  ```

- **Everything cloud-init printed:**

  ```bash
  multipass exec hardened -- sudo tail -50 /var/log/cloud-init-output.log
  ```

- **Check your YAML for mistakes:**

  ```bash
  multipass exec hardened -- sudo cloud-init schema --system
  ```

- **`launch` timed out:** the VM often finished anyway. Check with
  `multipass list` and the status command above.

## Clean up

This stops and permanently deletes both practice VMs:

```bash
multipass delete plain hardened
```

```bash
multipass purge
```

## Words you met

- **cloud-init:** the tool that reads a setup file on a machine's first boot.
  Almost every cloud, Lambda included, supports it.
- **SSH key:** a key pair. The public half goes on servers; the private half
  stays on your Mac and proves it's you.
- **Port:** a numbered door on a machine. SSH uses 22; the test web server used 8080.
- **Listening:** a program waiting for connections on a port.
- **Firewall:** rules that decide which connections reach those programs.
- **sudo:** run a command as the administrator (root).
- **unattended-upgrades:** Ubuntu's tool that installs security updates
  automatically.
