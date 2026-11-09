// Every branch: unit tests, image build, e2e.
// Tag vX.Y.Z: also pushes REGISTRY/qursor/backqup:X.Y.Z (and :latest).
// Jenkins setup: multibranch job with tag discovery, plus credentials
// 'qursor-registry' (username/password) and 'discord-webhook-internal'.
pipeline {
    agent any

    options {
        // the e2e uses a fixed compose project: two builds at once would collide
        disableConcurrentBuilds()
    }

    environment {
        REGISTRY = 'registry.qursor.it' // TODO: the real registry address
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
                    env.VERSION = env.TAG_NAME ? env.TAG_NAME.replaceFirst(/^v/, '') : "dev-${env.BUILD_NUMBER}"
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
            when { tag pattern: 'v\\d+\\.\\d+\\.\\d+', comparator: 'REGEXP' }
            steps {
                withCredentials([usernamePassword(credentialsId: 'qursor-registry',
                                                  usernameVariable: 'REG_USER',
                                                  passwordVariable: 'REG_PASS')]) {
                    sh '''
                        set -eu
                        echo "$REG_PASS" | docker login "$REGISTRY" -u "$REG_USER" --password-stdin
                        docker tag "backqup:ci-$BUILD_NUMBER" "$IMAGE:$VERSION"
                        docker tag "backqup:ci-$BUILD_NUMBER" "$IMAGE:latest"
                        docker push "$IMAGE:$VERSION"
                        docker push "$IMAGE:latest"
                    '''
                }
            }
        }
    }

    post {
        success {
            discordSend description: "backqup ${env.VERSION} ${env.TAG_NAME ? 'published to the registry' : 'tested'}.",
                    footer: "#${env.BUILD_NUMBER}", link: env.BUILD_URL, result: 'SUCCESS',
                    title: "[BACKQUP] Build SUCCEEDED", webhookURL: env.DISCORD_WEBHOOK_URL
        }
        failure {
            discordSend description: 'backqup build failed. Check the logs.',
                    footer: "#${env.BUILD_NUMBER}", link: env.BUILD_URL, result: 'FAILURE',
                    title: "[BACKQUP] Build FAILED", webhookURL: env.DISCORD_WEBHOOK_URL
        }
        always {
            sh 'docker rmi "backqup:ci-$BUILD_NUMBER" >/dev/null 2>&1 || true'
            sh 'docker logout "$REGISTRY" >/dev/null 2>&1 || true'
            cleanWs(notFailBuild: true)
        }
    }
}
