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
  useRefresh,
  useDataProvider,
  useNotify,
} from 'react-admin';
import { useQuery } from 'react-query';
import { LocalizationProvider } from '@mui/x-date-pickers/LocalizationProvider';
import { AdapterDayjs } from '@mui/x-date-pickers/AdapterDayjs';
import { DateTimePicker } from '@mui/x-date-pickers/DateTimePicker';
import dayjs, { Dayjs } from 'dayjs';

interface SecretInfoProps {
  uid: string | undefined;
}
interface SecretInfoParams {
  secret: string;
  delete_at: Dayjs | undefined | null;
  pending_period: string;
}

const SecretInfo = (props: SecretInfoProps) => {
  const { uid } = props;
  const [hasSecret, setHasSecret] = React.useState<boolean>(false);
  const [status, setStatus] = React.useState<string>('');
  const [params, setParams] = React.useState<SecretInfoParams>({ secret: '', delete_at: null, pending_period: "" });
  const secretQuery = useQuery({
    queryKey: ["secret"],
    queryFn: () => dataProvider.getSecret("secret", { uid: uid }).catch(() => { return { secret: "", delete_at: null, pending_period: "" } }),
  })
  const statusQuery = useQuery({
    queryKey: ["client"],
    queryFn: () => dataProvider.getOne("client", { id: uid }).then((json: any) => json.data.status),
  })
  const translate = useTranslate();
  const dataProvider = useDataProvider();
  const notify = useNotify();
  const refresh = useRefresh();

  React.useEffect(() => {
    if (!secretQuery.isLoading) {
      const data = secretQuery.data;
      const pending_period = data.pending_period ? Math.floor(parseInt(data.pending_period.slice(0, -1)) / 24).toString() : "";
      setParams({
        secret: data.secret,
        delete_at: data.delete_at ? dayjs(data.delete_at) : null,
        pending_period: pending_period
      })
      if (data.secret !== "") {
        setHasSecret(true);
      } else {
        setHasSecret(false);
      }
    }
  }, [secretQuery.data, secretQuery.isLoading]);

  React.useEffect(() => {
    if (!statusQuery.isLoading) {
      const data = statusQuery.data;
      setStatus(data);
    }
  }, [statusQuery.data, statusQuery.isLoading]);

  const onClickCreate = () => {
    dataProvider.createSecret("secret", {
      target: uid,
      secret: params.secret,
      delete_at: params.delete_at && params.delete_at.toISOString(),
      pending_period: params.pending_period
    }).then(async () => {
      notify('secret.created', { type: 'info' });
      refresh();
    }).catch(() => {
      notify('error.createError', { type: 'error' });
    })
  }

  return (
    <LocalizationProvider dateAdapter={AdapterDayjs}>
      <Box sx={{ width: 1 }}>
        <Typography variant="h5" sx={{ mb: 2 }}>
          {translate("secret.createTitle")}
        </Typography>
        <Card sx={{ width: 1 }}>
          <CardContent sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
            <Typography variant="body1" sx={{ mr: 2 }}>
              {translate("client.fields.status")}:{!statusQuery.isLoading && translate(`client.status.${status}`)}
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
              onClick={onClickCreate}
              disabled={
                hasSecret ||
                params.secret === "" ||
                params.delete_at === null ||
                (params.pending_period === "" && status === "ISSUED")
              }
              sx={{ ml: 1 }}
            >
              {translate("secret.create")}
            </Button>
          </CardContent>
        </Card>
      </Box>
    </LocalizationProvider >
  )
}

export default SecretInfo;