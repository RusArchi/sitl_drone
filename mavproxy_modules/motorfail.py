"""MAVProxy module: send MOTOR_FAILURE_SET (id 11070).

MAVProxy has no generic "send an arbitrary message" command, so a custom
message needs a module like this one to be reachable from the console.

The filename must be motorfail.py, not mavproxy_motorfail.py: MAVProxy tries
`MAVProxy.modules.mavproxy_<name>` and then the bare `<name>`, so the
mavproxy_ prefix only works for files inside MAVProxy's own package.

Load it with the directory on PYTHONPATH:

    PYTHONPATH=$PWD/mavproxy_modules sim_vehicle.py ...
    module load motorfail

Then:

    motorfail 3          fail motor 3
    motorfail 3 off      restore motor 3
    motorfail status     show what this module last sent
"""

# Name the dialect explicitly. mavutil.mavlink defaults to the v1.0 "all"
# dialect, which does not contain MOTOR_FAILURE_SET.
from pymavlink.dialects.v20 import ardupilotmega as apm
from MAVProxy.modules.lib import mp_module


class MotorFailModule(mp_module.MPModule):
    def __init__(self, mpstate):
        super(MotorFailModule, self).__init__(mpstate, "motorfail",
                                              "inject a motor failure")
        self.last_sent = None
        self.add_command('motorfail', self.cmd_motorfail,
                         'fail or restore a motor',
                         ['<status>', '(MOTOR)'])

    def usage(self):
        return "usage: motorfail <1-4> [on|off] | motorfail status"

    def cmd_motorfail(self, args):
        if len(args) == 0:
            print(self.usage())
            return

        if args[0] == 'status':
            if self.last_sent is None:
                print("motorfail: nothing sent yet")
            else:
                motor, failure_type = self.last_sent
                print("motorfail: last sent motor %u type %u"
                      % (motor, failure_type))
            return

        try:
            motor = int(args[0])
        except ValueError:
            print(self.usage())
            return

        if not 1 <= motor <= 4:
            print("motorfail: motor must be 1-4, got %d" % motor)
            return

        state = args[1].lower() if len(args) > 1 else 'on'
        if state in ('on', 'fail', 'stop'):
            failure_type = apm.MOTOR_FAILURE_TYPE_STOPPED
        elif state in ('off', 'restore', 'none'):
            failure_type = apm.MOTOR_FAILURE_TYPE_NONE
        else:
            print(self.usage())
            return

        self.master.mav.motor_failure_set_send(
            self.target_system,
            self.target_component,
            motor,
            failure_type)

        self.last_sent = (motor, failure_type)
        print("motorfail: sent motor %u type %u to %u/%u"
              % (motor, failure_type,
                 self.target_system, self.target_component))


def init(mpstate):
    """Entry point MAVProxy calls on 'module load motorfail'."""
    return MotorFailModule(mpstate)
