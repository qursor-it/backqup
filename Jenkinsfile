// DEV job (Jenkins job "backqup-dev", branch main, triggered by GitHub push).
// arm64 agent: unit tests, image build, e2e, then pushes
// REGISTRY/qursor/backqup:dev and :dev-<sha> for the DEV servers (arm64 only).
// Credentials: 'qursor-registry' (username/password), 'discord-webhook-internal'.
pipeline {
    agent { label 'arm64 && docker' }

    options {
        // the e2e uses a fixed compose project: two builds at once would collide
        disableConcurrentBuilds()
    }

    environment {
        REGISTRY = 'registry.qursor.dev'
        IMAGE = "${REGISTRY}/qursor/backqup"
        DISCORD_WEBHOOK_URL = credentials('discord-webhook-internal')
        DOCKER_BUILDKIT = '1'
        BUILDKIT_PROGRESS = 'plain'
    }

    stages {
        stage('Unit tests') {
            steps {
                sh 'docker build --target test .'
            }
        }

        stage('Build image') {
            steps {
                script {
                    env.VERSION = "dev-${env.GIT_COMMIT.take(7)}"
                }
                sh 'docker build --build-arg VERSION="$VERSION" -t "backqup:ci-$BUILD_NUMBER" .'
            }
        }

        stage('E2E') {
            steps {
                sh 'BACKQUP_IMAGE="backqup:ci-$BUILD_NUMBER" sh tests/e2e/run.sh'
            }
        }

        stage('Push') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'qursor-registry',
                                                  usernameVariable: 'REG_USER',
                                                  passwordVariable: 'REG_PASS')]) {
                    sh '''
                        set -eu
                        echo "$REG_PASS" | docker login "$REGISTRY" -u "$REG_USER" --password-stdin
                        docker tag "backqup:ci-$BUILD_NUMBER" "$IMAGE:$VERSION"
                        docker tag "backqup:ci-$BUILD_NUMBER" "$IMAGE:dev"
                        docker push "$IMAGE:$VERSION"
                        docker push "$IMAGE:dev"
                        docker rmi "$IMAGE:$VERSION" "$IMAGE:dev" >/dev/null 2>&1 || true
                    '''
                }
            }
        }
    }

    post {
        success {
            discordSend description: "backqup ${env.VERSION} published to the registry (dev, arm64).",
                    footer: "#${env.BUILD_NUMBER}", link: env.BUILD_URL, result: 'SUCCESS',
                    title: "[BACKQUP-DEV] Build SUCCEEDED", webhookURL: env.DISCORD_WEBHOOK_URL
        }
        failure {
            discordSend description: 'backqup dev build failed. Check the logs.',
                    footer: "#${env.BUILD_NUMBER}", link: env.BUILD_URL, result: 'FAILURE',
                    title: "[BACKQUP-DEV] Build FAILED", webhookURL: env.DISCORD_WEBHOOK_URL
        }
        always {
            sh 'docker rmi "backqup:ci-$BUILD_NUMBER" >/dev/null 2>&1 || true'
            sh 'docker logout "$REGISTRY" >/dev/null 2>&1 || true'
            cleanWs(notFailBuild: true)
        }
    }
}
