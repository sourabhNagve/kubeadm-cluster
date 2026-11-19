# Node IAM role. The only permission is AmazonSSMManagedInstanceCore, which lets the SSM agent
# register the instance so you can use Session Manager and Run Command (no SSH).
# See docs/ssm-guide.md. For production, split this into control-plane and worker roles
# (docs/production-notes.md).

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster}-node-role"
  description        = "Nodes of ${var.cluster}: SSM access only"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster}-node-profile"
  role = aws_iam_role.node.name
}
