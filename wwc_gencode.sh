#生成amqp协议代码

python2 codegen.py header D:\Project\Erlang\rabbitmq-server\deps\rabbitmq_codegen\amqp-rabbitmq-0.9.1.json D:\Project\Erlang\rabbitmq-server\deps\rabbit\include\rabbit_framing.hrl
python2 codegen.py body D:\Project\Erlang\rabbitmq-server\deps\rabbitmq_codegen\amqp-rabbitmq-0.9.1.json D:\Project\Erlang\rabbitmq-server\deps\rabbit\src\rabbit_framing_amqp_0_9_1.erl

