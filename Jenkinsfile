// Per-run container name: nso-ci-<job>-<build number>.
// Build numbers are per JOB, and a multibranch project has one job per branch
// (master, feature branches, PRs) that can build on the same agent at the same
// time. "nso-ci-<BUILD_NUMBER>" alone would therefore collide (master #5 and
// feature #5) and one build would kill the other's container (setup_nso_container
// `up` removes any container with its name first). Adding the job name makes the
// name unique per job; long job names are shortened and given a hash of the full
// job name so they stay unique and short enough to be a valid DNS label.
def nsoContainerName() {
  def job = env.JOB_NAME.replaceAll('[^A-Za-z0-9_.-]', '-')
  if (job.length() > 30) {
    job = job.substring(0, 18) + '-' + Math.abs(env.JOB_NAME.hashCode())
  }
  return "nso-ci-${job}-${env.BUILD_NUMBER}".toString()
}

pipeline {
  agent { label 'node-3' }

  parameters {
    choice(
      name: 'DEPLOY_TARGET',
      // 'none' MUST be first: Jenkins choice parameters default to the first
      // entry, so any build that doesn't explicitly set this (webhook/SCM
      // triggers, "Build Now" without "Build with Parameters") defaults to
      // no deployment instead of silently deploying to 'dev'.
      choices: ['none', 'dev', 'stage', 'prod'],
      description: 'CD target environment. none=no deploy (default). Deployment additionally requires branch release/* (or FORCE_DEPLOY) and a fully green CI/CT run.'
    )
    booleanParam(
      name: 'FORCE_DEPLOY',
      defaultValue: false,
      description: 'Override the release/* branch restriction and allow CD from any branch. Default false — leave unchecked unless you explicitly need to deploy from a non-release branch. Does NOT bypass the CI/CT test-pass requirement.'
    )
    string(
      name: 'NSO_TARGET_HOST',
      defaultValue: 'root@10.127.199.16',
      description: 'SSH target for CD (user@host). Jenkins credential nso-deploy-ssh must match this user.'
    )
  }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
    timeout(time: 60, unit: 'MINUTES')
    disableConcurrentBuilds()
    // SonarQube is treated as a warning-only gate, so we deliberately do not
    // stop downstream stages for this quality gate outcome. Test stages and
    // deployment gates remain the actual blockers for CI/CT/CD.
  }

  environment {
    PACKAGES_DIR            = 'packages'
    // Fallback only — overwritten in 'Prepare' from nso-dependencies.yaml's
    // nso-version: field (e.g. "6.4.1"), which is also the exact version
    // download_dependencies.sh fetches. NSO_VERSION must match that full
    // patch version, not just major.minor, or 'NSO Container' can't find the
    // downloaded nso-<ver>.container-image-build...signed.bin file.
    NSO_VERSION             = '6.4.1'
    NSO_CONTAINER_NAME      = "${nsoContainerName()}"
    CONTAINER_RUNTIME       = 'docker'
    // Keep the loaded NSO image (cisco-nso-build:<ver>, ~730 MB) on the agent
    // between builds. The container is still removed every run; only the image
    // is kept, so later builds skip the signed.bin extract + `docker load`
    // (~75s) and download_dependencies.sh skips re-fetching the signed.bin.
    // Costs one image of disk per NSO version. Set 'true' to delete it after
    // every build instead.
    NSO_CLEANUP_IMAGE       = 'false'
    // RESTCONF login for the Functional Testing (CXTA) stage. The user name is
    // not a secret. The password is generated once per build in the Prepare
    // stage (NSO_RESTCONF_PASSWORD), provisioned by setup_nso_container.sh into
    // this build's disposable nso-ci-<job>-<build> container, and forwarded to
    // CXTA by variable name only. If this ever points at a persistent/shared
    // NSO instance, bind a Jenkins credential (withCredentials) instead.
    NSO_RESTCONF_USER       = 'admin'
    ARTIFACT_DIR            = '.artifacts'
    NSO_ARTIFACT_BASE_URL   = 'file://${WORKSPACE}/binaries/nso'
    NSO_TARGET_HOST         = "${params.NSO_TARGET_HOST}"
    NSO_TARGET_PACKAGES_DIR = '/var/opt/ncs/packages/'
    GIT_REF                 = "${env.BRANCH_NAME ?: env.GIT_BRANCH ?: 'unknown'}"
    SONAR_PROJECT_KEY       = 'ai-first-nso'
    SONAR_PROJECT_NAME      = 'ai-first-nso'
    SONAR_HOST_URL          = 'https://engci-sonar-blr.cisco.com/sonar'
    SONAR_SCANNER_IMAGE     = 'sonarsource/sonar-scanner-cli:latest'
  }

  stages {

    stage('Prepare') {
      steps {
        sh 'mkdir -p reports .artifacts && chmod +x scripts/*.sh'
        // Free what earlier aborted/crashed runs leaked on this agent before we
        // allocate more: stopped/old containers labelled ci.owner=aifirst-nso
        // (nso-ci-* / cxta-*) and unused nso-test-network-* networks. This is what clears "all predefined
        // address pools have been fully subnetted". Best-effort, never fails
        // the build. Only resources we can identify by name are touched (no
        // generic prune), so other containers/networks/images on the agent and
        // other branch jobs building at the same time are left alone.
        sh 'bash scripts/cleanup.sh stale || true'
        script {
          def runtime = 'docker'
          // One provisioner: generated here, consumed by later stages by name.
          // python secrets avoids the tr|head SIGPIPE under pipefail.
          env.NSO_RESTCONF_PASSWORD = sh(
            script: '''set +x
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
''',
            returnStdout: true
          ).trim()
          if (!env.NSO_RESTCONF_PASSWORD) {
            error('Failed to generate the per-build NSO RESTCONF password')
          }
          env.RUNTIME_AVAILABLE = sh(
            script: "command -v ${runtime} >/dev/null 2>&1 && echo yes || echo no",
            returnStdout: true
          ).trim()
          if (env.RUNTIME_AVAILABLE != 'yes') {
            echo "WARNING: Container runtime '${runtime}' not found on this agent — NSO stages will be skipped."
          }

          // Resolve the exact NSO version from nso-dependencies.yaml (the
          // first "nso-version:" found, nested under whichever project
          // block(s) exist — the project key name itself, e.g.
          // "example-l3vpn 0.1:", is free-form and not parsed). This is the
          // same full patch version (e.g. "6.4.1") download_dependencies.sh
          // downloads, so NSO_VERSION must track it exactly rather than stay
          // hardcoded — otherwise 'NSO Container' looks for the wrong
          // signed.bin filename.
          def resolvedNsoVersion = sh(
            script: '''grep -m1 -E "^[[:space:]]+nso-version:" nso-dependencies.yaml 2>/dev/null | sed -E 's/^[[:space:]]+nso-version:[[:space:]]*"?([0-9.]+)"?.*/\\1/' ''',
            returnStdout: true
          ).trim()
          if (resolvedNsoVersion) {
            env.NSO_VERSION = resolvedNsoVersion
          } else {
            echo "WARNING: could not read nso-version: from nso-dependencies.yaml — keeping fallback NSO_VERSION=${env.NSO_VERSION}"
          }
          echo "==> NSO_VERSION=${env.NSO_VERSION} (from nso-dependencies.yaml)"

          // Requirement (1): CD may only run for release/* branches, unless
          // the operator explicitly opts in via the FORCE_DEPLOY parameter
          // (default false) when triggering "Build with Parameters".
          env.IS_RELEASE_BRANCH = (env.GIT_REF ==~ /^release\/.*/) ? 'true' : 'false'
          def branchAllowed = env.IS_RELEASE_BRANCH == 'true' || params.FORCE_DEPLOY
          echo "==> CD gating: branch='${env.GIT_REF}' isReleaseBranch=${env.IS_RELEASE_BRANCH} forceDeploy=${params.FORCE_DEPLOY} deployTarget=${params.DEPLOY_TARGET}"
          if (params.DEPLOY_TARGET != 'none' && !branchAllowed) {
            echo "WARNING: DEPLOY_TARGET='${params.DEPLOY_TARGET}' was requested but branch '${env.GIT_REF}' is not release/* and FORCE_DEPLOY is false — CD will be skipped."
          }
        }
      }
    }

    stage('CI') {
      stages {
        stage('Download Dependencies') {
          steps {
            script {
              withCredentials([usernamePassword(
                credentialsId: 'tailf-download-creds',
                usernameVariable: 'TAILF_USERNAME',
                passwordVariable: 'TAILF_PASSWORD'
              )]) {
                sh 'bash scripts/download_dependencies.sh'
              }
            }
          }
        }
        stage('Gitleaks') {
          environment {
            GITLEAKS_IMAGE = 'ghcr.io/gitleaks/gitleaks:latest'
            GITLEAKS_MODE    = 'detect'
            REPORT_PATH      = 'gitleaks-report.json'
          }
          steps {
            sh '''
              if ! command -v docker >/dev/null 2>&1; then
                echo "ERROR: Docker is not available on this Jenkins agent." >&2
                exit 1
              fi
              bash scripts/gitleaks.sh
            '''
          }
          post {
            always {
              // Archive the GitLeaks JSON report whether secrets were found or not.
              archiveArtifacts(
                artifacts: 'gitleaks-report.json,.artifacts/gitleaks-report.json',
                allowEmptyArchive: true,
                fingerprint: false
              )
            }
          }
        }
        stage('SonarQube') {
          steps {
            script {
              try {
                withCredentials([
                  string(credentialsId: 'SONAR_TOKEN', variable: 'SONAR_TOKEN')
                ]) {
                  sh 'bash scripts/sonarqube_scan.sh'
                }
              } catch (err) {
                echo "WARNING: SonarQube quality gate failed; continuing without failing the pipeline. ${err}"
                currentBuild.result = 'UNSTABLE'
              }
            }
          }
          post {
            always {
              archiveArtifacts artifacts: 'reports/sonar.status', allowEmptyArchive: true, fingerprint: false
            }
          }
        }
        stage('NSO Container') {
          when { expression { return env.RUNTIME_AVAILABLE == 'yes' } }
          steps { sh 'bash scripts/setup_nso_container.sh up' }
        }
        stage('Build Packages') {
          when { expression { return env.RUNTIME_AVAILABLE == 'yes' } }
          steps { sh 'bash scripts/setup_packages.sh' }
        }
      }
    }

    stage('CT') {
      when { expression { return env.RUNTIME_AVAILABLE == 'yes' } }
      stages {
        stage('Netsim')        { steps { sh 'bash scripts/netsim_simulation.sh' } }
        stage('Dry-run')       { steps { sh 'bash scripts/dry_run_validation.sh' } }
        stage('Commit & Check'){ steps { sh 'bash scripts/service_commit_check.sh' } }
        stage('Functional Testing') {
          steps {
            sh 'bash scripts/validate_cxta_pipeline_contract.sh'
            sh 'bash scripts/pyats_robot_validation.sh'
          }
        }
        stage('Report')             { steps { sh 'bash scripts/report_generation.sh' } }
      }
    }

    // Publish runs after CT (tests) have passed, not right after the build —
    // we only want to package and hand off artifacts that have cleared
    // Netsim/Dry-run/Commit & Check/Functional Testing, not ones straight off the build.
    stage('Publish') {
      when { expression { return env.RUNTIME_AVAILABLE == 'yes' } }
      steps { sh 'bash scripts/publish_artifact.sh' }
    }

    stage('CD') {
      when {
        allOf {
          // (1) Never deploy unless explicitly requested.
          expression { return params.DEPLOY_TARGET != 'none' }
          // (1) Only release/* branches trigger CD, unless FORCE_DEPLOY was
          // explicitly checked on a "Build with Parameters" run (default false).
          expression { return env.IS_RELEASE_BRANCH == 'true' || params.FORCE_DEPLOY }
          // (2) Never deploy if any earlier stage (CI/CT/Publish) failed or
          // left the build UNSTABLE — CT test failures must block CD.
          expression { return currentBuild.currentResult == 'SUCCESS' }
        }
      }
      stages {
        stage('Approval') {
          when { expression { return params.DEPLOY_TARGET in ['stage', 'prod'] } }
          steps {
            input message: "Deploy to ${params.DEPLOY_TARGET} on ${NSO_TARGET_HOST}?", ok: 'Deploy'
          }
        }
        stage('Deploy') {
          steps {
            // The SSH Agent plugin isn't installed on this controller (confirmed by
            // the "No such DSL method 'sshagent'" failure), and the nso-deploy-ssh
            // credential turned out to be a "Username with password" credential
            // rather than an SSH private key (sshUserPrivateKey errored with
            // "Credentials 'nso-deploy-ssh' is of type 'Username with password'").
            // Bind it with the matching usernamePassword step instead; the scripts
            // authenticate ssh/scp with SSH_PASSWORD via sshpass or SSH_ASKPASS
            // (see setup_ssh_password_auth in scripts/lib.sh).
            withCredentials([usernamePassword(credentialsId: 'nso-deploy-ssh', usernameVariable: 'SSH_USER', passwordVariable: 'SSH_PASSWORD')]) {
              sh '''
                set -euo pipefail
                mkdir -p reports
                echo "==> CD deploy: target=${NSO_TARGET_HOST} packages_dir=${NSO_TARGET_PACKAGES_DIR} env=${DEPLOY_TARGET}"
                bash scripts/deploy_packages.sh "${DEPLOY_TARGET}"
              '''
            }
          }
        }
        stage('Reload') {
          steps {
            withCredentials([usernamePassword(credentialsId: 'nso-deploy-ssh', usernameVariable: 'SSH_USER', passwordVariable: 'SSH_PASSWORD')]) {
              sh '''
                set -euo pipefail
                mkdir -p reports
                bash scripts/reload_packages.sh
              '''
            }
          }
        }
        stage('Notify') {
          steps {
            script {
              def notify = {
                sh "bash scripts/commit_status_notification.sh success 'Deployed to ${params.DEPLOY_TARGET} (${NSO_TARGET_HOST}:${NSO_TARGET_PACKAGES_DIR})' || true"
              }
              try {
                withCredentials([string(credentialsId: 'webex-token', variable: 'WEBEX_TOKEN')]) {
                  notify()
                }
              } catch (ignored) {
                notify()
              }
            }
          }
        }
      }
    }
  }

  post {
    always {
      // Cleanup runs on success, failure AND abort (a regular stage would be
      // skipped after an earlier failure — exactly when leaks happen).
      // Removes this run's NSO + CXTA containers (with their volumes), the
      // NSO image and any per-build network, then sweeps leaks from earlier
      // runs. Best-effort: never changes the build result. The timeout keeps a
      // hung docker daemon from wedging the post block.
      timeout(time: 10, unit: 'MINUTES') {
        sh 'bash scripts/cleanup.sh all || true'
      }
      archiveArtifacts artifacts: '.artifacts/**, reports/**', allowEmptyArchive: true, fingerprint: true
      
      // Publish Robot Framework test results if they exist
      script {
        if (fileExists('reports/robot/output.xml')) {
          echo "Publishing Robot Framework test results..."
          robot(
            outputPath: 'reports/robot',
            reportFileName: 'report.html',
            logFileName: 'log.html',
            outputFileName: 'output.xml',
            passThreshold: 100.0,
            unstableThreshold: 80.0,
            onlyCritical: false,
            disableArchiveOutput: false
          )
        }
      }
    }
    failure {
      sh 'bash scripts/commit_status_notification.sh failure "Build #${BUILD_NUMBER} failed" || true'
    }
  }
}
