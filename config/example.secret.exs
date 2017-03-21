use Mix.Config

config :sftpoison, sftp_connections:
  [%{
    name: :demo_sftp,
    domain: '',
    port: 22,
    user: '',
    password: '',
  }]
