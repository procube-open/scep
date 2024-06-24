import React from 'react';
import {
  Box,
  Card,
  CardContent,
  Typography,
  TextField,
  Button,
} from '@mui/material';
import {
  useTranslate,
  useDataProvider,
  useRefresh,
  useNotify,
} from 'react-admin';
import { LocalizationProvider } from '@mui/x-date-pickers/LocalizationProvider';
import { AdapterDayjs } from '@mui/x-date-pickers/AdapterDayjs';
import { DateTimePicker } from '@mui/x-date-pickers/DateTimePicker';
import dayjs, { Dayjs } from 'dayjs';

interface SecretInfoProps {
  uid: string | undefined;
  render: boolean;
}
interface SecretInfoParams {
  secret: string;
  delete_at: Dayjs | undefined | null;
  pending_period: string;
}
const useTriggerEffect = (callback: () => void): (() => void) => {
  const [trigger, setTrigger] = React.useState(false);

  React.useEffect(() => {
    if (trigger) {
      callback();
      setTrigger(false);
    }
  }, [trigger, callback]);

  const triggerEffect = React.useCallback(() => setTrigger(true), []);

  return triggerEffect;
};

const SecretInfo = (props: SecretInfoProps) => {
  const { uid, render } = props;
  const [hasSecret, setHasSecret] = React.useState<boolean>(false);
  const [status, setStatus] = React.useState<string>('');
  const [params, setParams] = React.useState<SecretInfoParams>({ secret: '', delete_at: null, pending_period: "" });
  const translate = useTranslate();
  const dataProvider = useDataProvider();
  const notify = useNotify();
  const refresh = useRefresh();

  React.useEffect(() => {
    dataProvider.getOne("client", { id: uid }).then(async (json: any) => {
      setStatus(json.data.status);
    })
  }, []);
  const triggerGetClientEffect = useTriggerEffect(() => {
    dataProvider.getOne("client", { id: uid }).then(async (json: any) => {
      setStatus(json.data.status);
    })
  });
  const triggerGetSecretEffect = useTriggerEffect(() => {
    dataProvider.getSecret("secret", { uid: uid }).then((json: any) => {
      setParams({
        secret: json.secret,
        delete_at: dayjs(json.delete_at),
        pending_period: String(Math.floor(parseInt(json.pending_period.slice(0, -1)) / 24))
      })
      setHasSecret(true);
    }).catch(() => {
      setHasSecret(false);
    })
  });

  React.useEffect(() => {
    triggerGetSecretEffect();
    triggerGetClientEffect();
  }, [render]);

  const onClickCreate = () => {
    dataProvider.createSecret("secret", {
      target: uid,
      secret: params.secret,
      delete_at: params.delete_at && params.delete_at.toISOString(),
      pending_period: params.pending_period
    }).then(async (response: any) => {
      notify('secret.created', { type: 'info' });
      refresh();
      triggerGetSecretEffect();
      triggerGetClientEffect();
    }).catch(() => {
      notify('error.createError', { type: 'error' });
    })
  }
  return (
    <LocalizationProvider dateAdapter={AdapterDayjs}>
      <Box sx={{ width: 1 }}>
        <Typography variant="h6" sx={{ ml: 1 }} children={translate("secret.createTitle")} />
        <Card sx={{ width: 1 }}>
          <CardContent sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
            <Typography variant="body1" sx={{ mr: 2 }}>
              {translate("client.fields.status")}:{translate(`client.status.${status}`)}
            </Typography>
            <TextField
              label={translate("secret.fields.secret")}
              value={params.secret}
              variant="outlined"
              disabled={hasSecret || status === "PENDING"}
              onChange={(event) => setParams({ ...params, secret: event.target.value })}
              sx={{ ml: 1 }}
            />
            <DateTimePicker
              ampm={false}
              disablePast
              label={translate("secret.fields.delete_at")}
              value={params.delete_at}
              onChange={(newValue) => setParams({ ...params, delete_at: newValue })}
              disabled={hasSecret || status === "PENDING"}
              slotProps={{
                textField: { variant: "outlined" },
                actionBar: {
                  actions: ['accept', 'clear'],
                },
              }}
              sx={{ ml: 1 }}
            />
            <TextField
              label={translate("secret.fields.pending_period")}
              value={params.pending_period}
              variant="outlined"
              disabled={hasSecret || status === "INACTIVE" || status === "PENDING"}
              type="number"
              InputProps={{
                endAdornment: <Typography>{translate("secret.fields.pending_period_suffix")}</Typography>
              }}
              onChange={(event) => setParams({ ...params, pending_period: event.target.value })}
              sx={{ ml: 1 }}
            />
            <Button
              variant="contained"
              color="primary"
              children={translate("secret.create")}
              onClick={onClickCreate}
              disabled={
                hasSecret ||
                params.secret === "" ||
                params.delete_at === null ||
                (params.pending_period === "" && status === "ISSUED")
              }
              sx={{ ml: 1 }}
            />
          </CardContent>
        </Card>
      </Box>
    </LocalizationProvider >
  )
}

export default SecretInfo;