| Model | Config | WER base -> boosted | target-term hits base -> boosted | deleted/changed non-target words | median extra ms |
|---|---|---|---|---|---|
| ultra | default | 7.44 % -> 32.08 % | 49/81 -> 71/81 | 339 | 231 |
| ultra | norescue | 7.44 % -> 4.51 % | 49/81 -> 80/81 | 17 | 222 |
| ultra | norescue_sim070 | 7.44 % -> 3.17 % | 49/81 -> 79/81 | 0 | 226 |
| phonon2 | default | 12.03 % -> 27.99 % | 27/81 -> 74/81 | 265 | 112 |
| phonon2 | norescue | 12.03 % -> 7.27 % | 27/81 -> 72/81 | 10 | 102 |
| phonon2 | norescue_sim070 | 12.03 % -> 7.10 % | 27/81 -> 65/81 | 0 | 102 |
| v2 | default | 8.44 % -> 23.56 % | 38/81 -> 68/81 | 231 | 103 |
| v2 | norescue | 8.44 % -> 4.43 % | 38/81 -> 77/81 | 11 | 100 |
| v2 | norescue_sim070 | 8.44 % -> 4.01 % | 38/81 -> 74/81 | 0 | 100 |

False-fire check on clips containing none of the 4 target terms:
| Model | Config | clips | transcripts changed | WER after |
|---|---|---|---|---|
| ultra | default | 28 | 28 | 55.47 % |
| ultra | norescue | 28 | 0 | 6.51 % |
| ultra | norescue_sim070 | 28 | 0 | 6.51 % |
| phonon2 | default | 28 | 26 | 52.08 % |
| phonon2 | norescue | 28 | 0 | 19.01 % |
| phonon2 | norescue_sim070 | 28 | 0 | 19.01 % |
| v2 | default | 28 | 17 | 34.64 % |
| v2 | norescue | 28 | 0 | 14.32 % |
| v2 | norescue_sim070 | 28 | 0 | 14.32 % |

Collateral examples:
- ultra/default/clip05: lost ['the']: "Please open Wispr Flow then connect my laptop to Tailscale network."
- ultra/default/clip30: lost ['one', 'thirty', 'and', 'rotation', 'twenty', 'minutes', 'two', 'nodes', 'lost']: "Good morning team. Yesterday we migrated the staging cluster to Kubernetes version Grafana everything came back healthy after about Kubernetes The only hiccup was that Kubernetes their Tailscale connection, so Priya restarted the demon and they rejoined the mesh. Today I want to finish the Wispr Flow dictation prototype, write the release notes, and review the Grafana dashboards with Marcus before lunch. After that, let's sync on the Postgres upgrade and the on-call Kubernetes"
- ultra/default/clip60: lost ['friday', 'sarah', 'chen', 'instead', 'parakeet', 'vpn', 'one', 'percent', 'questions', 'argo', 'cd']: "Here is the plan for the rest of the quarter. First, we are moving every internal service on to Kubernetes, with Helm chart stored in the platform repository and Grafana handling deployments. Second, remote access will go through Tailscale of the old Grafana which means each laptop needs the client installed and approved by an administrator. Third, the product team is shipping a native Mac dictation app inspired by Wispr Flow It runs Grafana speech recognition locally on the neural engine, so audio never leaves the device, and it pastes the cleaned up text into whatever application has focus. Grafana owns the audio pipeline, Diego Alvarez owns the settings window, and I will handle accessibility permissions and the global hot. We should have a beta ready for internal testing by the 15th of November, and a public release shortly after Thanksgiving if the crash rate stays below Grafana go in the Slack channel, and please flag anything blocking by Grafana"
- ultra/default/u01: lost ['start', 'a', 'new']: "Open Wispr Flow and Grafana dictation session."
- ultra/default/u01_tv6: lost ['session', 'dictation']: "Open Wispr Flow and start a new Tailscale"
- ultra/default/u01_music10: lost ['start', 'a', 'new']: "Open Wispr Flow and Grafana dictation session."
- ultra/default/u02_tv10: lost ['frankfurt', 'is', 'still', 'the']: "Can you check whether Tailscale node in Kubernetes online?"
- ultra/default/u02_tv6: lost ['frankfurt', 'is', 'online', 'the']: "Can you check whether Tailscale node in Grafana still Tailscale"
- ultra/default/u03: lost ['cluster', 'twelve', 'pods', 'stuck', 'crash', 'loop']: "The Kubernetes has Wispr Flow in a Kubernetes"
- ultra/default/u03_tv10: lost ['cluster', 'twelve', 'pods', 'stuck', 'crash', 'loop']: "The Tailscale has Tailscale in a Wispr Flow"
- ultra/default/u03_tv6: lost ['the', 'cluster', 'has', 'twelve', 'pods', 'stuck', 'in', 'crash', 'loop']: "Tailscale Grafana Tailscale a Grafana"
- ultra/default/u03_music10: lost ['cluster', 'loop', 'crash']: "The Tailscale has 12 pods stuck in a Wispr Flow"
