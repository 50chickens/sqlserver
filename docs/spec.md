Spec: AWS Emulator backplane for SSIS/SSRS pipeline
Draft, 14 November 2026
1. Goal and scope
Scaffold an end-to-end pipeline locally. A call to the AWS EC2 API (RunInstances) against a local AWS Emulator creates what looks like a Windows EC2 instance but is really a Windows Server Core Docker container. The SQL Server SSIS and SSRS install then runs inside that container. Everything except the SSIS and SSRS services is mocked by the emulator.
In scope: EC2 instance lifecycle mapped to containers, user data execution, installer media delivery, the test pipeline.
Out of scope: Auto Scaling (the real AWS implementation will handle it later), RDS behavior, domain join, production use. AWS says the emulator is not for production workloads or security validation.
2. What to clone
Repo
Purpose
https://github.com/aws/aws-emulator
The emulator source. This is what you patch. Released under CC0.
https://github.com/aws/aws-emulator-evaluation-suite
Fidelity tests. Use it to confirm your patches do not regress existing EC2 behavior.
https://github.com/aws/api-models-aws
AWS API models (the spec the emulator is built from). Reference for EC2 request and response shapes.
Fork the emulator rather than cloning it directly, so your patches live in your own repository and you can merge upstream changes. The upstream repo is updated frequently by agents, so pin to a commit or release tag.
3. Build environment
• A Windows Server (or Windows 11 Pro) host that can run Windows containers. Linux containers cannot be started from a Windows-container daemon at the same time, and a Linux-hosted emulator cannot start Windows containers.
• Docker Engine in Windows-container mode, with the host OS build compatible with the base image tag (process isolation needs a matching build; Hyper-V isolation relaxes this).
• The emulator toolchain. AWS describes an embedded mode that runs inside a Rust test process, so expect Rust. Confirm in the repo's README and build files, and build natively on Windows.
• A Docker client library for your language (for Rust, for example, bollard) or shell-out to the docker CLI for the first version.
• Git, and the AWS CLI or an SDK for testing against the emulator endpoint.
4. Source changes
All changes are in the EC2 service of the emulator. Confirm first how EC2 is currently implemented (metadata only, most likely) and where the handlers live.
4.1 Instance lifecycle
• RunInstances: resolve the AMI to a container image, create and start a container, record the instance ID to container ID mapping, return the instance in pending, then move it to running once the container is up.
• DescribeInstances and DescribeInstanceStatus: report state from the real container state.
• StopInstances, StartInstances: stop and start the container.
• TerminateInstances: stop and remove the container, move through shutting-down to terminated.
4.2 AMI to image mapping
• A config file mapping fake AMI IDs to Docker images, for example an AMI ID to mcr.microsoft.com/windows/servercore:<tag>, or to your own pre-built image.
• DescribeImages should return those AMIs so launch-template code that validates the AMI works.
4.3 User data and command execution
• Decode the base64 UserData from RunInstances and run it inside the container with docker exec (PowerShell) after start.
• Capture stdout and stderr to a log, and expose the exit code. Consider supporting GetConsoleOutput for this.
• Decide how failure surfaces: instance stays running with a failed status check, or is moved to terminated. This matters for any code that later relies on health checks.
4.4 Metadata and networking
• The EC2 metadata service (169.254.169.254) will not exist in a container. Either skip it or inject the same values as environment variables for the user data script.
• Return the container's IP as the instance private IP. Public IP and subnets can be fake values.
• Instance profiles: pass fake credentials pointing at the emulator endpoint so scripts in the container can call S3 and Secrets Manager.
4.5 Restart behavior
Emulator state is in memory, so instance records are lost on restart. Label each container with its instance ID. On startup, scan labelled containers and either rebuild the instance records or remove them.
5. Configuration
• Emulator endpoint, for example AWS_ENDPOINT_URL=http://localhost:4566 (confirm the actual port and variable in the README).
• Dummy credentials and a region.
• AMI to image mapping file.
• Docker host (named pipe on Windows).
• Container resource limits (SQL Server setup needs generous memory and disk).
6. Installer media
The SSIS and SSRS install needs SQL Server media. Options:
1.  Store the media in the emulator's S3, and have the user data download it into the container.
2.  Bake the media into a custom image (large).
3.  Bind-mount a host folder into the container.
Option 1 best mirrors the real pipeline. Use an unattended install (setup.exe /ACTION=Install /FEATURES=IS /QUIET plus a configuration file) for SSIS, and the SSRS installer in silent mode, then run the SSRS configuration step against the target database. Expect several GB of image and slow first pulls, so pre-pull the base image.
7. End-to-end pipeline
1.  Start the emulator (native process on the Windows host).
2.  Create an S3 bucket and upload installer media and scripts.
3.  Create secrets for service accounts in Secrets Manager.
4.  Call RunInstances with the mapped AMI and the user data.
5.  Poll DescribeInstances until running.
6.  Wait for user data to finish, then check the install: services present, dtexec runs a smoke-test package, SSRS web service responds.
7.  Call TerminateInstances and confirm the container is removed.
8. Deploy and run
• Build the patched emulator on the Windows host and run it as a service or a scheduled process.
• Run the evaluation suite's EC2 tests to check you have not broken existing behavior.
• Keep the AMI mapping and pipeline scripts in version control next to the fork.
9. Open questions to verify in the repo
• Language, build commands, and how services are organised.
• Whether EC2 is implemented at all, and how far (instances, images, user data).
• Whether the emulator can run natively on Windows, or only as a Linux binary or Docker image.
• How it handles unsupported operations and whether it has an extension point that avoids patching core code.
• Whether anything in the emulator already starts containers (for example for Lambda).