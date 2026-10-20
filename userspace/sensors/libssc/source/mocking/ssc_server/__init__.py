import sys

# Allow importing Protobuf generated Python packages standalone
from . import ssc_common_pb2
sys.modules["ssc_common_pb2"] = ssc_common_pb2

from . import ssc_sensor_accelerometer_pb2
sys.modules["ssc_sensor_accelerometer_pb2"] = ssc_sensor_accelerometer_pb2

from . import ssc_sensor_gyroscope_pb2
sys.modules["ssc_sensor_gyroscope_pb2"] = ssc_sensor_gyroscope_pb2

from . import ssc_sensor_light_pb2
sys.modules["ssc_sensor_light_pb2"] = ssc_sensor_light_pb2

from . import ssc_sensor_magnetometer_pb2
sys.modules["ssc_sensor_magnetometer_pb2"] = ssc_sensor_magnetometer_pb2

from . import ssc_sensor_proximity_pb2
sys.modules["ssc_sensor_proximity_pb2"] = ssc_sensor_proximity_pb2

from . import ssc_sensor_rotationvector_pb2
sys.modules["ssc_sensor_rotationvector_pb2"] = ssc_sensor_rotationvector_pb2

from . import ssc_sensor_suid_pb2
sys.modules["ssc_sensor_suid_pb2"] = ssc_sensor_suid_pb2
