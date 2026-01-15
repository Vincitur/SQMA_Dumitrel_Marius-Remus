pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                // Check out the code from the Git repository
                checkout scm
            }
        }
        stage('Test Basic Operations') {
            steps {
                // Run the Basic operations tests
                bat 'run_tests.bat BasicOperationsTest'
            }
        }
        stage('Test Advanced Operations') {
            steps {
                // Run the Advanced operations tests
                bat 'run_tests.bat AdvancedOperationsTest'
            }
        }
        stage('Test String Operations') {
            steps {
                // Run the String operations tests
                bat 'run_tests.bat StringOperationsTest'
            }
        }
    }
    
    post {
        always {
            // Clean up or simple report
            echo 'Pipeline execution finished.'
        }
        failure {
            echo 'Some tests failed!'
        }
    }
}
