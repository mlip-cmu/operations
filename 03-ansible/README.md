# 03 · Configure many servers with Ansible

The blogging platform runs on several servers: web servers (nginx) that receive the requests,
and spam filter servers that run the spam filter from [01](../01-container/). This project
configures four such servers with one playbook. For the demo, the "servers" are containers
(`servers/compose.yaml`); Ansible connects to them with `docker exec` instead of SSH.

**Problem.** Configuration done by hand on each server is slow, and the servers become
different over time: someone changes a value on one server to fix a problem, an update is
done on three of four servers, or the new API key is set on only half of the servers. Nobody
knows any more what runs where and with which settings.

**Idea.** Describe the wanted state of all servers in files under version control (the
inventory, variables, templates, and a playbook), and let a tool bring each server to that
state. The tool changes only what is different (idempotence), so you can run it again at any
time, also to find and repair manual changes (drift). Secrets go into the same repository,
but encrypted.

The inventory says which servers exist and which role each has (`inventory.ini`):

```ini
[webservers]
web1
web2

[spamservers]
spam1
spam2
```

A task in the playbook writes a configuration file from a template; only if the file changes,
the handler restarts the service (`site.yml`):

```yaml
- name: Write the spam filter configuration
  ansible.builtin.template:
    src: spamfilter.env.j2
    dest: /etc/spamfilter/spamfilter.env
  notify: Restart the spam filter
```

The nginx template connects the servers: it forwards comments to all servers of the group
`spamservers`, with the API key from the encrypted vault (`templates/blog-nginx.conf.j2`):

```nginx
upstream spamfilter {
{% for host in groups['spamservers'] %}
    server {{ host }}:{{ spamfilter_port }};
{% endfor %}
}
```

## What the code shows

`demo.sh` (output in [`transcript.txt`](transcript.txt)):

1. The inventory has two groups; Ansible reaches all four servers.
2. The API key is in the repository only in encrypted form (`group_vars/all/vault.yml`).
3. First run: 6 changes on each spam filter server, 3 on each web server.
4. The web servers forward comments to the spam filter servers and add the API key; a request
   without the key gets `invalid API key`.
5. Second run: `changed=0` on all servers.
6. Drift: a manual change of the threshold on `spam2` shows in a dry run
   (`--check --diff`); the next run repairs only `spam2` and restarts its spam filter.
7. A new API key: one run changes all four servers (spam filters and web servers) together.
   For the demo the new key is given on the command line; normally you change the vault file
   (`ansible-vault edit group_vars/all/vault.yml`).

The tasks that write the API key have `diff: false`: a diff would show the secret in the
output and in CI logs. `vault-password.txt` is in the repository only for the demo; never
commit a real vault password.

## Tools

- [Ansible](https://docs.ansible.com): a tool for configuration management and deployment
  that runs tasks on many servers, without an agent on the servers. Here: the playbook, the
  templates, the vault, and the dry run.
- [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html): encrypts
  files with secrets. Here: the API key of the spam filter.
- [community.docker](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_connection.html):
  an Ansible collection for Docker. Here: its connection plugin lets Ansible reach the
  containers instead of SSH.
- [nginx](https://nginx.org): a web server and reverse proxy. Here: the web servers forward
  `/check` to the spam filter servers.
- [Supervisor](https://supervisord.org): a process manager. Here: runs the spam filter on the
  spam filter servers, so that Ansible can restart it (on a normal server, this is systemd).

## Run

With [Docker](https://docs.docker.com/get-docker/) and [uv](https://docs.astral.sh/uv/):

```sh
./demo.sh                                       # start four servers and run all steps
docker compose -f servers/compose.yaml up -d --build
uv run ansible-playbook site.yml --check --diff # dry run
uv run ansible-playbook site.yml                # configure the servers
docker compose -f servers/compose.yaml down
```

The spam filter servers use the image `spamfilter:1.0` from [01](../01-container/); `demo.sh`
builds it if necessary.
